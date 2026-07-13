import * as path from "node:path";

/** A `b.step("name", …)` declaration site (0-based line). */
export interface NamedStep {
  name: string;
  line: number;
}

/**
 * Structural facts extracted from a `build.zig` by lightweight scanning
 * (not a full Zig parse). Good enough to place code lenses and to map an
 * executable's `root_source_file` to the named step that runs it.
 */
export interface BuildScriptInfo {
  /** Line of `fn build(` / `pub fn build(`, or `null` if absent. */
  buildFnLine: number | null;
  steps: NamedStep[];
  /**
   * Workspace-relative path (forward slashes) of an executable's root
   * source → the named step that `dependOn`s an `addRunArtifact` of that
   * executable. Install-only wiring is ignored so we don't suggest
   * `zig build install` as a "run" action.
   */
  executableRootToRunStep: Map<string, string>;
}

/**
 * Parses `build.zig` source for:
 * - the `build` entry function
 * - every `b.step("name", …)` (lens targets)
 * - executable root → run-step links via the common
 *   `step = b.step(…)` / `exe = b.addExecutable(…)` /
 *   `run = b.addRunArtifact(exe)` / `step.dependOn(&run.step)` pattern
 */
export function parseBuildScript(source: string): BuildScriptInfo {
  const buildFnLine = findBuildFnLine(source);
  const steps = findNamedSteps(source);
  const executableRootToRunStep = linkExecutableRootsToRunSteps(source, steps);
  return { buildFnLine, steps, executableRootToRunStep };
}

function findBuildFnLine(source: string): number | null {
  const re = /^(?![ \t]*\/\/)[ \t]*(?:pub\s+)?fn\s+build\s*\(/gm;
  const match = re.exec(source);
  if (!match) return null;
  return lineAt(source, match.index);
}

function findNamedSteps(source: string): NamedStep[] {
  const steps: NamedStep[] = [];
  // Matches both `b.step("name", …)` and `const foo = b.step("name", …)`.
  const re = /\bb\.step\s*\(\s*"([^"]+)"/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(source))) {
    steps.push({ name: match[1], line: lineAt(source, match.index) });
  }
  return steps;
}

/**
 * Walks the common Zig build-graph pattern:
 *
 * ```
 * const run_step = b.step("cli", "…");
 * const exe = b.addExecutable(.{ .root_module = b.createModule(.{
 *     .root_source_file = b.path("cmd/docent.zig"),
 * }), });
 * const run_cmd = b.addRunArtifact(exe);
 * run_step.dependOn(&run_cmd.step);
 * ```
 *
 * and produces `cmd/docent.zig → "cli"`.
 */
function linkExecutableRootsToRunSteps(
  source: string,
  steps: NamedStep[],
): Map<string, string> {
  const stepVarToName = new Map<string, string>();
  const exeVarToRoot = new Map<string, string>();
  const runVarToExe = new Map<string, string>();

  // `foo = b.step("name"`
  {
    const re = /(\w+)\s*=\s*b\.step\s*\(\s*"([^"]+)"/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source))) {
      stepVarToName.set(match[1], match[2]);
    }
  }

  // `foo = b.addExecutable(` … find `.root_source_file = b.path("…")`
  // inside the call (paren-depth tracked so nested `createModule` is fine).
  {
    const re = /(\w+)\s*=\s*b\.addExecutable\s*\(/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source))) {
      const varName = match[1];
      const callStart = match.index + match[0].length - 1; // at '('
      const callBody = sliceBalancedCall(source, callStart);
      if (callBody === null) continue;
      const root = extractRootSourceFile(callBody);
      if (root) exeVarToRoot.set(varName, normalizeRelPath(root));
    }
  }

  // Also: `b.addExecutable` assigned through `root_module = mod` where
  // `mod = b.addModule` / `b.createModule` was defined earlier with a root.
  // Cover `foo = b.createModule(` / `foo = b.addModule(` roots, then
  // `addExecutable` that references `.root_module = foo`.
  const moduleVarToRoot = new Map<string, string>();
  {
    const re = /(\w+)\s*=\s*b\.(?:createModule|addModule)\s*\(/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source))) {
      const varName = match[1];
      const callStart = match.index + match[0].length - 1;
      const callBody = sliceBalancedCall(source, callStart);
      if (callBody === null) continue;
      const root = extractRootSourceFile(callBody);
      if (root) moduleVarToRoot.set(varName, normalizeRelPath(root));
    }
  }
  {
    const re = /(\w+)\s*=\s*b\.addExecutable\s*\(/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source))) {
      const varName = match[1];
      if (exeVarToRoot.has(varName)) continue; // already has inline root
      const callStart = match.index + match[0].length - 1;
      const callBody = sliceBalancedCall(source, callStart);
      if (callBody === null) continue;
      const modRef = callBody.match(/\.root_module\s*=\s*(\w+)/);
      if (!modRef) continue;
      const root = moduleVarToRoot.get(modRef[1]);
      if (root) exeVarToRoot.set(varName, root);
    }
  }

  // `foo = b.addRunArtifact(exe)`
  {
    const re = /(\w+)\s*=\s*b\.addRunArtifact\s*\(\s*(\w+)\s*\)/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source))) {
      runVarToExe.set(match[1], match[2]);
    }
  }

  // `stepVar.dependOn(&runVar.step)`
  const rootToStep = new Map<string, string>();
  {
    const re = /(\w+)\.dependOn\s*\(\s*&(\w+)\.step\s*\)/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source))) {
      const stepVar = match[1];
      const runVar = match[2];
      const stepName = stepVarToName.get(stepVar);
      const exeVar = runVarToExe.get(runVar);
      if (!stepName || !exeVar) continue;
      const root = exeVarToRoot.get(exeVar);
      if (!root) continue;
      // First mapping wins; later dependOns (e.g. install) shouldn't override.
      if (!rootToStep.has(root)) rootToStep.set(root, stepName);
    }
  }

  // Fallback: if there's exactly one executable root and a step named
  // "run", use that even without a clean dependOn chain (common template).
  if (rootToStep.size === 0 && exeVarToRoot.size === 1) {
    const hasRun = steps.some((s) => s.name === "run");
    if (hasRun) {
      const root = exeVarToRoot.values().next().value;
      if (root) rootToStep.set(root, "run");
    }
  }

  return rootToStep;
}

/** Returns the source between matching `(` … `)` starting at `openParen`. */
function sliceBalancedCall(source: string, openParen: number): string | null {
  if (source[openParen] !== "(") return null;
  let depth = 0;
  for (let i = openParen; i < source.length; i++) {
    const c = source[i];
    if (c === "(") depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) return source.slice(openParen + 1, i);
    }
  }
  return null;
}

function extractRootSourceFile(callBody: string): string | null {
  const match = callBody.match(
    /\.root_source_file\s*=\s*b\.path\s*\(\s*"([^"]+)"\s*\)/,
  );
  return match?.[1] ?? null;
}

function normalizeRelPath(p: string): string {
  return p.replace(/\\/g, "/");
}

function lineAt(source: string, offset: number): number {
  let line = 0;
  for (let i = 0; i < offset && i < source.length; i++) {
    if (source[i] === "\n") line++;
  }
  return line;
}

/** 0-based lines of `fn main(` / `pub fn main(` declarations (not in comments). */
export function findMainFnLines(source: string): number[] {
  const lines: number[] = [];
  const re = /^(?![ \t]*\/\/)[ \t]*(?:pub\s+)?fn\s+main\s*\(/gm;
  let match: RegExpExecArray | null;
  while ((match = re.exec(source))) {
    lines.push(lineAt(source, match.index));
  }
  return lines;
}

/**
 * Resolves `fileFsPath` against a workspace folder root + build-script map
 * to the step that runs that file as an executable root, or `null`.
 */
export function runStepForFile(
  workspaceRootFsPath: string,
  info: BuildScriptInfo,
  fileFsPath: string,
): string | null {
  const rel = normalizeRelPath(path.relative(workspaceRootFsPath, fileFsPath));
  if (!rel || rel.startsWith("..")) return null;
  return info.executableRootToRunStep.get(rel) ?? null;
}
