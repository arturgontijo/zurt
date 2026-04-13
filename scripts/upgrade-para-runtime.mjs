#!/usr/bin/env node
//
// Upgrade a parachain runtime via the parachain's own sudo pallet, then
// notify the relay chain about the new validation code.
//
// Flow:
//   1. [Parachain] sudo.sudo(system.authorizeUpgradeWithoutChecks(codeHash))
//   2. [Parachain] system.applyAuthorizedUpgrade(code)
//   3. [Relay]     sudo.sudo(paras.forceScheduleCodeUpgrade(paraId, code, relayBlock+2))
//
// Moonbase's system.applyAuthorizedUpgrade directly replaces :code without
// signaling the relay chain via cumulus. Step 3 fixes the PVF mismatch by
// telling the relay to expect the new validation code.
//
// The parachain sudo key must be Alith.
// The relay chain must have a sudo pallet (e.g. rococo-local).
//
// Usage:
//   node upgrade-para-runtime.mjs <para_ws> <relay_ws> <wasm_path> <para_id>
//

import { readFileSync } from "fs";
import { execSync } from "child_process";
import { createRequire } from "module";
import { dirname, join } from "path";

const bin = execSync("which polkadot-js-api", { encoding: "utf8" }).trim();
const resolved = execSync(
  `readlink -f "${bin}" 2>/dev/null || realpath "${bin}" 2>/dev/null || echo "${bin}"`,
  { encoding: "utf8" },
).trim();
const require = createRequire(join(dirname(resolved), "node_modules") + "/");
const { ApiPromise, WsProvider, Keyring } = require("@polkadot/api");
const { cryptoWaitReady } = require("@polkadot/util-crypto");

const ALITH_PRIVATE_KEY =
  "0x5fb92d6e98884f76de468fa3f6278f8807c48bebc13595d45af5bdc4da702133";

const [paraWs, relayWs, wasmPath, paraIdStr] = process.argv.slice(2);
if (!paraWs || !relayWs || !wasmPath || !paraIdStr) {
  console.error(
    "Usage: upgrade-para-runtime.mjs <para_ws> <relay_ws> <wasm_path> <para_id>",
  );
  process.exit(1);
}
const paraId = parseInt(paraIdStr, 10);

function blake2b256(data) {
  const { blake2AsHex } = require("@polkadot/util-crypto");
  return blake2AsHex(data, 256);
}

function sendAndWait(tx, signer, api, label) {
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, events, dispatchError }) => {
      if (status.isInBlock) {
        console.log(`  ${label}: in block ${status.asInBlock.toHex()}`);
      }
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            try {
              const decoded = api.registry.findMetaError(
                dispatchError.asModule,
              );
              reject(
                new Error(
                  `${label}: ${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`,
                ),
              );
            } catch {
              reject(new Error(`${label}: ${dispatchError.toString()}`));
            }
          } else {
            reject(new Error(`${label}: ${dispatchError.toString()}`));
          }
          return;
        }
        const sudoEvt = events.find(
          ({ event }) => event.section === "sudo" && event.method === "Sudid",
        );
        if (sudoEvt) {
          const result = sudoEvt.event.data[0];
          if (result.isErr) {
            reject(
              new Error(
                `${label} sudo failed: ${JSON.stringify(result.toHuman())}`,
              ),
            );
            return;
          }
        }
        resolve(events);
      }
    });
  });
}

async function main() {
  await cryptoWaitReady();

  const wasmBytes = readFileSync(wasmPath);
  const wasmHex = "0x" + wasmBytes.toString("hex");
  const codeHash = blake2b256(wasmBytes);
  console.log(
    `WASM: ${wasmPath} (${(wasmBytes.length / 1024 / 1024).toFixed(1)} MB)`,
  );
  console.log(`Code hash: ${codeHash}`);
  console.log(`Para ID: ${paraId}`);

  // --- Connect to parachain ---
  console.log(`\nConnecting to parachain: ${paraWs}`);
  const paraApi = await ApiPromise.create({
    provider: new WsProvider(paraWs),
    noInitWarn: true,
  });
  const paraChain = await paraApi.rpc.system.chain();
  const paraVersion = paraApi.runtimeVersion.specVersion.toNumber();
  console.log(`  Chain: ${paraChain} (runtime ${paraVersion})`);

  const sudoKey = (await paraApi.query.sudo.key()).toString();
  console.log(`  Sudo key: ${sudoKey}`);

  const ethKeyring = new Keyring({ type: "ethereum" });
  const alith = ethKeyring.addFromUri(ALITH_PRIVATE_KEY);
  console.log(`  Alith: ${alith.address}`);

  if (sudoKey.toLowerCase() !== alith.address.toLowerCase()) {
    throw new Error(
      `Sudo key ${sudoKey} does not match Alith ${alith.address}`,
    );
  }

  // --- Step 1: Authorize on parachain ---
  console.log("\nStep 1: sudo.sudo(system.authorizeUpgradeWithoutChecks)...");
  const authorizeCall =
    paraApi.tx.system.authorizeUpgradeWithoutChecks(codeHash);
  const sudoAuthorize = paraApi.tx.sudo.sudo(authorizeCall);
  await sendAndWait(sudoAuthorize, alith, paraApi, "authorizeUpgrade");
  console.log("  OK");

  // --- Step 2: Apply on parachain ---
  console.log("\nStep 2: system.applyAuthorizedUpgrade...");
  const applyCall = paraApi.tx.system.applyAuthorizedUpgrade(wasmHex);
  await sendAndWait(applyCall, alith, paraApi, "applyAuthorizedUpgrade");
  console.log("  OK — parachain :code replaced locally");

  // Check new version
  await new Promise((r) => setTimeout(r, 6000));
  const newParaVersion = (
    await paraApi.rpc.state.getRuntimeVersion()
  ).specVersion.toNumber();
  console.log(`  Parachain runtime: ${paraVersion} → ${newParaVersion}`);

  // --- Step 3: Notify relay chain about new PVF ---
  console.log(`\nStep 3: Notifying relay chain about new validation code...`);
  console.log(`  Connecting to relay: ${relayWs}`);
  const relayApi = await ApiPromise.create({
    provider: new WsProvider(relayWs),
    noInitWarn: true,
  });
  const relayChain = await relayApi.rpc.system.chain();
  const relayVersion = relayApi.runtimeVersion.specVersion.toNumber();
  console.log(`  Relay: ${relayChain} (runtime ${relayVersion})`);

  // Check relay has sudo
  let relaySudoKey;
  try {
    relaySudoKey = (await relayApi.query.sudo.key()).toString();
  } catch {
    throw new Error(
      "Relay chain does not have a sudo pallet. Use rococo-local as the relay.",
    );
  }
  console.log(`  Relay sudo key: ${relaySudoKey}`);

  const srKeyring = new Keyring({ type: "sr25519" });
  const alice = srKeyring.addFromUri("//Alice");

  const currentBlock = (
    await relayApi.rpc.chain.getHeader()
  ).number.toNumber();
  const expectedAt = currentBlock + 2;
  console.log(
    `  Scheduling code upgrade for para ${paraId} at relay block #${expectedAt}...`,
  );

  const forceUpgrade = relayApi.tx.sudo.sudo(
    relayApi.tx.paras.forceScheduleCodeUpgrade(paraId, wasmHex, expectedAt),
  );
  await sendAndWait(forceUpgrade, alice, relayApi, "forceScheduleCodeUpgrade");
  console.log("  OK — relay now expects the new PVF");

  // Wait for the scheduled block
  console.log(`\n  Waiting for relay block #${expectedAt}...`);
  await new Promise((resolve) => {
    const unsub = relayApi.rpc.chain.subscribeNewHeads((header) => {
      const num = header.number.toNumber();
      if (num >= expectedAt + 2) {
        unsub.then((u) => u());
        resolve();
      }
    });
  });

  // Verify PVF hash on relay matches
  let relayCodeHash;
  try {
    relayCodeHash = (
      await relayApi.query.paras.currentCodeHash(paraId)
    ).toString();
  } catch {
    relayCodeHash = "unknown";
  }
  console.log(`  Relay PVF hash for para ${paraId}: ${relayCodeHash}`);
  console.log(`  Local code hash:                    ${codeHash}`);
  if (relayCodeHash === codeHash) {
    console.log("  Hashes match!");
  } else {
    console.log(
      "  WARNING: Hashes don't match yet. It may take a few more blocks.",
    );
  }

  // Final check
  console.log("\nWaiting for parachain blocks to resume...");
  await new Promise((r) => setTimeout(r, 30000));

  const finalVersion = (
    await paraApi.rpc.state.getRuntimeVersion()
  ).specVersion.toNumber();
  console.log(`\nFinal parachain runtime: ${finalVersion}`);
  console.log("Done!");

  await paraApi.disconnect();
  await relayApi.disconnect();
  process.exit(0);
}

main().catch((err) => {
  console.error("Fatal:", err.message || err);
  process.exit(1);
});
