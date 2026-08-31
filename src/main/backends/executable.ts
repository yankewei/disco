import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { delimiter, isAbsolute, join } from "node:path";

export function findExecutable(command: string): string | undefined {
  const searchDirectories = [
    ...(process.env.PATH?.split(delimiter) ?? []),
    join(homedir(), ".opencode", "bin"),
    join(homedir(), ".local", "bin"),
    join(homedir(), ".npm-global", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ];
  const candidates = isAbsolute(command)
    ? [command]
    : searchDirectories.map((directory) => join(directory, command));

  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  return undefined;
}
