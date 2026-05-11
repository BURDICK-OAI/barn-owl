#!/usr/bin/env node

import { webcrypto } from "node:crypto";
import fs from "node:fs";
import { spawnSync } from "node:child_process";

const { subtle } = webcrypto;

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function argValue(name) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    fail(`Missing ${name}.`);
  }
  return process.argv[index + 1];
}

function base64urlToBytes(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) {
    fail("Ciphertext must be base64url.");
  }
  return Buffer.from(value, "base64url");
}

async function decryptAPIKey(privateKeyPath, ciphertext) {
  const privateJwk = JSON.parse(fs.readFileSync(privateKeyPath, "utf8"));
  const privateKey = await subtle.importKey(
    "jwk",
    privateJwk,
    { name: "RSA-OAEP", hash: "SHA-256" },
    false,
    ["decrypt"],
  );

  const plaintext = await subtle.decrypt(
    { name: "RSA-OAEP" },
    privateKey,
    base64urlToBytes(ciphertext),
  );
  const apiKey = new TextDecoder().decode(plaintext).trim();
  if (!/^sk-[A-Za-z0-9_-]+$/.test(apiKey)) {
    fail("Decrypted value is not an OpenAI API key.");
  }
  return apiKey;
}

function saveToKeychainViaBarnOwl(apiKey) {
  const executableCandidates = [
    "/Applications/Barn Owl.app/Contents/MacOS/BarnOwlApp",
    "/Applications/Barn Owl.app/Contents/MacOS/BarnOwl",
  ];
  const executable = executableCandidates.find((candidate) => fs.existsSync(candidate));
  if (!executable) {
    fail("Barn Owl app executable was not found in /Applications.");
  }

  const result = spawnSync(
    executable,
    ["--install-api-key-from-env"],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        BARNOWL_API_KEY_TO_INSTALL: apiKey,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  if (result.status !== 0) {
    fail("Failed to save OpenAI API key to Keychain.");
  }
}

const privateKeyPath = argValue("--private-key");
const ciphertext = argValue("--ciphertext");
const apiKey = await decryptAPIKey(privateKeyPath, ciphertext);
saveToKeychainViaBarnOwl(apiKey);
process.stdout.write(
  JSON.stringify(
    {
      service: "com.barnowl.mac.openai",
      account: "OPENAI_API_KEY",
      wrote_plaintext_to_stdout: false,
    },
    null,
    2,
  ) + "\n",
);
