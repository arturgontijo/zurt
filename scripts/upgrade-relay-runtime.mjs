#!/usr/bin/env node
//
// Upgrade the relay chain runtime via sudo on a running network.
//
// Flow:
//   sudo.sudoUncheckedWeight(system.setCodeWithoutChecks(wasm), {refTime: 0, proofSize: 0})
//
// This is safe when upgrading between rococo-local runtimes from different
// polkadot-sdk versions, because they share the same spec_name ("rococo")
// and the same fast-runtime BABE epoch duration (~10 blocks).
//
// The relay chain must have a sudo pallet with Alice as the sudo key
// (standard for rococo-local).
//
// Usage:
//   node upgrade-relay-runtime.mjs <relay_ws> <wasm_path>
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

const [relayWs, wasmPath] = process.argv.slice(2);
if (!relayWs || !wasmPath) {
  console.error("Usage: upgrade-relay-runtime.mjs <relay_ws> <wasm_path>");
  process.exit(1);
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
  console.log(
    `WASM: ${wasmPath} (${(wasmBytes.length / 1024 / 1024).toFixed(1)} MB)`,
  );

  console.log(`\nConnecting to relay: ${relayWs}`);
  const api = await ApiPromise.create({
    provider: new WsProvider(relayWs),
    noInitWarn: true,
  });
  const chain = await api.rpc.system.chain();
  const version = api.runtimeVersion;
  console.log(
    `  Chain: ${chain} (spec: ${version.specName}/${version.specVersion})`,
  );

  let sudoKey;
  try {
    sudoKey = (await api.query.sudo.key()).toString();
  } catch {
    throw new Error("Relay chain does not have a sudo pallet.");
  }
  console.log(`  Sudo key: ${sudoKey}`);

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  console.log(`  Alice: ${alice.address}`);

  console.log(
    "\nUpgrading relay runtime via sudo.sudoUncheckedWeight(system.setCodeWithoutChecks)...",
  );

  const setCode = api.tx.system.setCodeWithoutChecks(wasmHex);
  const weight = { refTime: 0, proofSize: 0 };
  const sudoCall = api.tx.sudo.sudoUncheckedWeight(setCode, weight);
  await sendAndWait(sudoCall, alice, api, "setCodeWithoutChecks");
  console.log("  OK — relay runtime replaced");

  // Wait a few blocks for the new runtime to activate
  console.log("\nWaiting for new runtime to activate...");
  await new Promise((resolve) => {
    let count = 0;
    const unsub = api.rpc.chain.subscribeNewHeads(() => {
      count++;
      if (count >= 3) {
        unsub.then((u) => u());
        resolve();
      }
    });
  });

  const newVersion = (
    await api.rpc.state.getRuntimeVersion()
  ).specVersion.toNumber();
  console.log(
    `\nRelay runtime: ${version.specVersion} → ${newVersion}`,
  );
  console.log("Done!");

  await api.disconnect();
  process.exit(0);
}

main().catch((err) => {
  console.error("Fatal:", err.message || err);
  process.exit(1);
});
