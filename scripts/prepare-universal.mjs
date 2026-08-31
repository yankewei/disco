import { execFileSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

function readPackageVersion(packagePath) {
  const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
  return packageJson.version;
}

const claudeVersion = readPackageVersion(
  "node_modules/@anthropic-ai/claude-agent-sdk/package.json",
);
const temporaryDirectory = mkdtempSync(join(tmpdir(), "disco-universal-"));
const platformPackages = [
  {
    packageName: "@anthropic-ai/claude-agent-sdk-darwin-x64",
    version: claudeVersion,
  },
  {
    packageName: "@anthropic-ai/claude-agent-sdk-darwin-arm64",
    version: claudeVersion,
  },
];

try {
  writeFileSync(
    join(temporaryDirectory, "package.json"),
    JSON.stringify(
      {
        name: "disco-universal-dependencies",
        private: true,
        dependencies: Object.fromEntries(
          platformPackages.map(({ packageName, version }) => [
            packageName,
            version,
          ]),
        ),
      },
      null,
      2,
    ),
  );
  execFileSync(
    "npm",
    [
      "install",
      "--prefix",
      temporaryDirectory,
      "--ignore-scripts",
      "--no-package-lock",
      "--force",
    ],
    { stdio: "inherit" },
  );

  for (const { packageName } of platformPackages) {
    const sourcePath = join(temporaryDirectory, "node_modules", packageName);
    const destinationPath = join("node_modules", packageName);
    rmSync(destinationPath, { recursive: true, force: true });
    mkdirSync(dirname(destinationPath), { recursive: true });
    cpSync(sourcePath, destinationPath, { recursive: true });
  }
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
