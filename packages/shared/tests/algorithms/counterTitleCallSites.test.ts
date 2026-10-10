import * as fs from 'fs';
import * as path from 'path';

/**
 * Lint-style guard for the PR 1 → PR 2 hand-off (docs/SHARED_COUNTER_SETTINGS.md
 * §5 "Copy-side title call sites"): every `generateCounterTaskTitle(` /
 * `isAutoCounterTitle(` call in production code on BOTH platforms is listed
 * here with the reason it is correct. A copy-side call must pass the counter
 * ROOT's `CounterTitleSettings` (or a root's own), or a template-rendered
 * title reads as custom and a regenerated one ignores the templates.
 *
 * Remaining raw (settings-less) calls in COPY paths: 0. Every entry below is
 * either template-aware or a non-copy path. A new call site — or a removed one
 * — fails this test until the list is updated with its reason.
 */

const REPO = path.join(__dirname, '..', '..', '..', '..');
const ROOTS = ['apps/web/src', 'apps/ios/OYBC', 'packages/shared/src'];
/** The definitions themselves. */
const DEFINITIONS = new Set([
  'packages/shared/src/algorithms/taskTitle.ts',
  'apps/ios/OYBC/Helpers/TaskTitle.swift',
]);

const TEMPLATE_AWARE = 'template-aware: passes the root settings (a root, or a copy given its root)';
const NEW_TASK =
  'creates a NEW task / sub-task — no root templates apply; the formula is auto by definition, so any later copy mint re-renders it through the root';
const BLANK_FALLBACK = 'display fallback for a blank stored title (every counting title is stamped at creation)';

const ALLOWLIST: Record<string, { count: number; reason: string }> = {
  // ── iOS ──
  'apps/ios/OYBC/Database/AppDatabase+CompoundStructureEdit.swift': {
    count: 2,
    reason: `${NEW_TASK}; the existing-child edit passes the child's own settings`,
  },
  'apps/ios/OYBC/Database/AppDatabase+CountKindSwitch.swift': { count: 2, reason: TEMPLATE_AWARE },
  'apps/ios/OYBC/Helpers/CounterEditModel.swift': { count: 1, reason: TEMPLATE_AWARE },
  'apps/ios/OYBC/Helpers/RootFieldPropagation.swift': { count: 2, reason: TEMPLATE_AWARE },
  'apps/ios/OYBC/Views/BoardsTab/SquareEditTaskSheet.swift': {
    count: 5,
    reason: `${TEMPLATE_AWARE}; one settings-less call is the formula comparator in submittedTitle`,
  },
  'apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel+EditCommit.swift': {
    count: 1,
    reason: 'blank-title fallback at Save — the sheet already submits the templated title whenever the root templates differ from the formula',
  },
  'apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel.swift': { count: 1, reason: BLANK_FALLBACK },
  'apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundEditFieldsView.swift': { count: 1, reason: NEW_TASK },
  'apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundFieldsView.swift': { count: 1, reason: NEW_TASK },
  'apps/ios/OYBC/Views/CreateTab/Components/RisoPoolRowEditorView.swift': {
    count: 1,
    reason: "live preview of the draft's own fields (no root in scope); the formula is auto and the mint re-renders through the root",
  },
  'apps/ios/OYBC/Views/CreateTab/Components/RisoSpecialTaskPanel.swift': { count: 1, reason: NEW_TASK },
  'apps/ios/OYBC/Views/CreateTab/Components/TaskEditPatch.swift': { count: 2, reason: TEMPLATE_AWARE },
  'apps/ios/OYBC/Views/CreateTab/ViewModels/CreateFormViewModel.swift': { count: 3, reason: NEW_TASK },
  // ── web ──
  'apps/web/src/components/CountingStepFields.tsx': { count: 1, reason: NEW_TASK },
  'apps/web/src/components/board/cellModel.ts': { count: 1, reason: BLANK_FALLBACK },
  'apps/web/src/components/boardEdit/BoardEditTaskSheet.tsx': { count: 2, reason: TEMPLATE_AWARE },
  'apps/web/src/components/boardEdit/boardEditTaskSheetModel.ts': { count: 2, reason: TEMPLATE_AWARE },
  'apps/web/src/components/compoundWizard/compoundSubtaskDraft.ts': { count: 1, reason: NEW_TASK },
  'apps/web/src/components/counters/counterEditModel.ts': { count: 1, reason: TEMPLATE_AWARE },
  'apps/web/src/components/counters/counterRowTitle.ts': { count: 1, reason: TEMPLATE_AWARE },
  'apps/web/src/components/playground/SharedCounterPlayground.tsx': { count: 2, reason: 'dev-only playground' },
  'apps/web/src/db/operations/countKindSwitch.ts': { count: 2, reason: TEMPLATE_AWARE },
  'apps/web/src/db/taskEditPatch.ts': {
    count: 5,
    reason: `${TEMPLATE_AWARE} (seed / apply / existing-child edit); appendTypedChild + buildNewChildTask: ${NEW_TASK}`,
  },
  'apps/web/src/pages/createPage/createFormCounting.ts': { count: 3, reason: NEW_TASK },
  // ── shared ──
  'packages/shared/src/algorithms/rootFieldPropagation.ts': { count: 2, reason: TEMPLATE_AWARE },
};

const CALL = /generateCounterTaskTitle\(|isAutoCounterTitle\(/;
const COMMENT = /^\s*(\/\*|\*|\/\/)/;
const DEFINITION = /(function|func) (generateCounterTaskTitle|isAutoCounterTitle)\b/;

/** Production source files under `dir` (tests excluded). */
function sourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(path.join(REPO, dir), { withFileTypes: true })) {
    const rel = `${dir}/${entry.name}`;
    if (entry.isDirectory()) {
      if (entry.name === '__tests__' || entry.name === 'node_modules') continue;
      out.push(...sourceFiles(rel));
    } else if (/\.(ts|tsx|swift)$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name)) {
      out.push(rel);
    }
  }
  return out;
}

/** Call-site count per file (comment lines and the definitions excluded). */
function callSites(): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const root of ROOTS) {
    for (const file of sourceFiles(root)) {
      if (DEFINITIONS.has(file)) continue;
      const n = fs
        .readFileSync(path.join(REPO, file), 'utf8')
        .split('\n')
        .filter((line) => CALL.test(line) && !COMMENT.test(line) && !DEFINITION.test(line)).length;
      if (n > 0) counts[file] = n;
    }
  }
  return counts;
}

describe('counter title call sites (docs/SHARED_COUNTER_SETTINGS.md §5 PR 1 hand-off)', () => {
  it('every production call site is allowlisted with its reason — no raw copy-side call remains', () => {
    const expected = Object.fromEntries(Object.entries(ALLOWLIST).map(([f, e]) => [f, e.count]));
    expect(callSites()).toEqual(expected);
  });

  it('every allowlist entry carries a reason', () => {
    for (const entry of Object.values(ALLOWLIST)) expect(entry.reason.length).toBeGreaterThan(10);
  });
});
