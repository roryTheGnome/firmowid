"use strict";

const { execFileSync } = require("node:child_process");
const path = require("node:path");

const root = path.join(__dirname, "..", "..");
const patch = path.join(root, "assets", "patches", "live_toast.patch");

try {
  execFileSync("git", ["apply", "--reverse", "--check", patch], {
    cwd: root,
    stdio: "pipe"
  });
} catch {
  execFileSync("git", ["apply", patch], { cwd: root, stdio: "inherit" });
}