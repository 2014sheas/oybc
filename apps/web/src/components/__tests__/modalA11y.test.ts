import { describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import {
  TaskType,
  Timeframe,
  type Board,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';

// CI has no `.env.local`: anything that reaches `firebase/config` must be
// stubbed, and the two signed-out modals read `useAuth()`, which throws
// outside an AuthProvider.
vi.mock('../../firebase/config', () => ({ auth: {}, firestore: {} }));
vi.mock('../../firebase/useAuth', () => ({
  useAuth: () => ({
    signIn: async () => {},
    signUp: async () => {},
    signInWithGoogle: async () => {},
    signInWithApple: async () => {},
    signInAnonymously: async () => {},
    refreshAfterUpgrade: async () => {},
  }),
}));

import { CounterDeleteConfirmDialog } from '../counters/CounterDeleteConfirmDialog';
import { CreateCounterSheet } from '../counters/CreateCounterSheet';
import { TaskConfirmDeleteDialog } from '../../pages/tasks/TaskConfirmDeleteDialog';
import { TaskEditSheet } from '../../pages/tasks/TaskEditSheet';
import { RemoveSourceConfirmDialog } from '../wizard/RemoveSourceConfirmDialog';
import { BoardWizardCancelDialog } from '../wizard/BoardWizardCancelDialog';
import { DeriveCounterModal } from '../wizard/DeriveCounterModal';
import { NewTaskSheet } from '../wizard/NewTaskSheet';
import { MissingSourceDialog } from '../boards/MissingSourceDialog';
import { BoardEditTaskSheet } from '../boardEdit/BoardEditTaskSheet';
import { SquareTapMenu } from '../boardEdit/SquareTapMenu';
import { CellSwapModal } from '../CellSwapModal';
import { DetailModal } from '../InteractiveTaskSquare';
import { TaskDetailSheet } from '../TaskDetailSheet';
import { PoolEditSheet } from '../pools/PoolEditSheet';
import { PoolPickerSheet } from '../pools/PoolPickerSheet';
import { CoreDefaultsSheet } from '../boardSettings/CoreDefaultsSheet';
import { ShareBoardSheet } from '../share/ShareBoardSheet';
import { RisoGreenlog } from '../play/RisoGreenlog';
import { SignInModal } from '../signedOut/SignInModal';
import { UpgradeModal } from '../signedOut/UpgradeModal';
import { CoreWindowPickerPopover } from '../../pages/core-board-browser/CoreWindowPickerPopover';

/**
 * 2026-09 audit (web a11y): every modal routes through `useModalA11y`, so
 * every one must announce itself as modal. Rendered with `react-dom/server`
 * — `environment: 'node'`, no DOM — so this pins the markup half of the
 * contract (aria-modal, a focusable container, a `data-modal-cancel` target
 * for the dialogs that open on Cancel). The keyboard half (Escape, the Tab
 * wrap, focus hand-back) is driven in a real browser by
 * `e2e/member-rules.spec.ts` + `e2e/modal-focus.spec.ts`, and the
 * wrap decision itself by `hooks/__tests__/useModalA11y.test.ts`.
 *
 * Dialogs that only open from internal state (BoardCard
 * confirms, Library / Source picker sheets, the Profile confirms, the
 * Account-security sheet, the pool-delete inline confirm, the repeating-
 * board wizard overlay) can't be opened in a string render; the source
 * guard in `hooks/__tests__/useModalA11y.test.ts` keeps them on the hook.
 */

const NOW = '2026-09-23T00:00:00.000Z';
const noop = (): void => {};

function makeTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

const TASK = makeTask('t-1', { title: 'Read' });
const COUNTER = makeTask('t-2', {
  title: 'Run 30 miles',
  type: TaskType.COUNTING,
  action: 'Run',
  unit: 'miles',
  maxCount: 30,
});

function inRouter(el: React.ReactElement): React.ReactElement {
  return React.createElement(MemoryRouter, null, el);
}

interface DialogCase {
  name: string;
  element: () => React.ReactElement;
  /** Text of the control initial focus lands on, for `initialFocus: 'cancel'` dialogs. */
  cancelLabel?: string;
}

const CASES: DialogCase[] = [
  {
    name: 'CounterDeleteConfirmDialog',
    cancelLabel: 'Cancel',
    element: () =>
      React.createElement(CounterDeleteConfirmDialog, {
        counterName: 'Push-ups',
        memberCount: 0,
        derivedWindowCounterCount: 0,
        members: [],
        busy: false,
        onConfirm: noop,
        onCancel: noop,
      }),
  },
  {
    name: 'TaskConfirmDeleteDialog',
    cancelLabel: 'Cancel',
    element: () =>
      React.createElement(TaskConfirmDeleteDialog, {
        task: TASK,
        impact: {
          boardTaskCount: 0,
          affectedBoardIds: [],
          affectedBoards: [],
          childLinkCount: 0,
          parentLinkCount: 0,
          counterMemberCount: 0,
          counterMembers: [],
          derivedWindowCounterCount: 0,
        },
        onConfirm: noop,
        onCancel: noop,
      }),
  },
  {
    name: 'RemoveSourceConfirmDialog',
    cancelLabel: 'Cancel',
    element: () =>
      React.createElement(RemoveSourceConfirmDialog, {
        displayName: 'Morning Kickstart',
        lossSentence: "You'll lose 1 exclusion.",
        editingRepeatingBoard: false,
        onConfirm: noop,
        onCancel: noop,
      }),
  },
  {
    name: 'BoardWizardCancelDialog',
    cancelLabel: 'Keep Editing',
    element: () =>
      React.createElement(BoardWizardCancelDialog, {
        isOpen: true,
        canSaveDraft: true,
        onSaveDraft: noop,
        onDiscard: noop,
        onKeepEditing: noop,
      }),
  },
  {
    name: 'MissingSourceDialog',
    cancelLabel: 'Not now',
    element: () =>
      React.createElement(MissingSourceDialog, {
        template: { id: 'tpl-1', name: 'Weekly' } as RecurringBoardTemplate,
        onRemoveSource: noop,
        onPause: noop,
        onDismiss: noop,
      }),
  },
  {
    name: 'DeriveCounterModal',
    element: () =>
      React.createElement(DeriveCounterModal, {
        source: COUNTER,
        maxCountInput: '10',
        onMaxCountChange: noop,
        error: null,
        onCancel: noop,
        onSave: noop,
      }),
  },
  {
    name: 'CreateCounterSheet',
    element: () =>
      inRouter(
        React.createElement(CreateCounterSheet, {
          open: true,
          onClose: noop,
          tasks: [],
          userId: 'user-1',
          onCreated: noop,
        }),
      ),
  },
  {
    name: 'TaskEditSheet',
    element: () =>
      React.createElement(TaskEditSheet, { task: TASK, onSubmit: async () => {}, onCancel: noop }),
  },
  {
    name: 'TaskDetailSheet',
    element: () =>
      inRouter(React.createElement(TaskDetailSheet, { taskId: TASK.id, onClose: noop })),
  },
  {
    name: 'NewTaskSheet',
    element: () =>
      inRouter(
        React.createElement(NewTaskSheet, {
          isOpen: true,
          onClose: noop,
          userId: 'user-1',
          onTaskCreated: noop,
          onCompositeCreated: noop,
        }),
      ),
  },
  {
    name: 'BoardEditTaskSheet',
    element: () =>
      React.createElement(BoardEditTaskSheet, { task: TASK, onDone: noop, onCancel: noop }),
  },
  {
    name: 'CellSwapModal',
    element: () =>
      React.createElement(CellSwapModal, {
        mode: 'add',
        candidateTasks: [TASK],
        onClose: noop,
        onConfirm: noop,
      }),
  },
  {
    name: 'DetailModal (InteractiveTaskSquare)',
    element: () =>
      React.createElement(DetailModal, {
        sq: { id: 'sq-1', title: 'Read', type: 'normal' },
        state: { isCompleted: false, currentCount: 0, completedStepIds: new Set<string>() },
        onClose: noop,
        onToggleComplete: noop,
        onIncrementCount: noop,
        onDecrementCount: noop,
      }),
  },
  {
    name: 'PoolEditSheet',
    element: () =>
      React.createElement(PoolEditSheet, {
        userId: 'user-1',
        templates: [],
        allTasks: [TASK],
        browsableTasks: [TASK],
        onClose: noop,
        onSaved: noop,
        onDeleted: noop,
      }),
  },
  {
    name: 'PoolPickerSheet',
    element: () =>
      React.createElement(PoolPickerSheet, {
        userId: 'user-1',
        pools: [],
        templates: [],
        achievableTaskIdsByTemplateId: undefined,
        tasksById: {},
        browsableTasks: [],
        selectedPoolIds: [],
        onTogglePool: noop,
        onPoolCreated: noop,
        onClose: noop,
      }),
  },
  {
    name: 'CoreDefaultsSheet',
    element: () =>
      React.createElement(CoreDefaultsSheet, {
        userId: 'user-1',
        timeframe: Timeframe.WEEKLY,
        existingDefault: undefined,
        pools: [],
        templates: [],
        achievableTaskIdsByTemplateId: undefined,
        allTasks: [],
        browsableTasks: [],
        onClose: noop,
        onSaved: noop,
      }),
  },
  {
    name: 'ShareBoardSheet',
    element: () =>
      React.createElement(ShareBoardSheet, {
        boardName: 'Week board',
        completedTasks: 9,
        totalTasks: 9,
        linesCompleted: 8,
        onDismiss: noop,
      }),
  },
  {
    name: 'RisoGreenlog',
    element: () =>
      React.createElement(RisoGreenlog, {
        boardName: 'Week board',
        boardSize: 3,
        bingos: 8,
        streak: 0,
        onShare: noop,
        onNewBoard: noop,
        onClose: noop,
      }),
  },
  {
    name: 'CoreWindowPickerPopover',
    element: () =>
      React.createElement(CoreWindowPickerPopover, {
        timeframe: Timeframe.MONTHLY,
        weekStartDay: 'monday',
        boardsByStart: new Map<string, Board>(),
        displayedWindowStart: '2026-09-01',
        now: new Date('2026-09-23T12:00:00'),
        onSelect: noop,
        onClose: noop,
      }),
  },
  {
    name: 'SignInModal',
    element: () =>
      React.createElement(SignInModal, { mode: 'signin', onClose: noop, onSwitchMode: noop }),
  },
  {
    name: 'UpgradeModal',
    element: () => React.createElement(UpgradeModal, { onClose: noop }),
  },
];

/** Every opening tag carrying a dialog role. */
function dialogTags(html: string): string[] {
  return html.match(/<[a-z]+\b[^>]*\brole="(?:alert)?dialog"[^>]*>/g) ?? [];
}

describe('every modal announces itself through useModalA11y', () => {
  it.each(CASES)('$name renders aria-modal="true" on its dialog element', ({ element }) => {
    const tags = dialogTags(renderToStaticMarkup(element()));
    expect(tags.length).toBeGreaterThan(0);
    for (const tag of tags) {
      expect(tag).toContain('aria-modal="true"');
      // The container can take focus itself (fallback initial focus, and
      // a click on dead space inside the sheet keeps focus in the trap).
      expect(tag).toContain('tabindex="-1"');
    }
  });

  it.each(CASES.filter((c) => c.cancelLabel !== undefined))(
    '$name marks its safe choice ("$cancelLabel") as the initial-focus target',
    ({ element, cancelLabel }) => {
      const html = renderToStaticMarkup(element());
      const targets = html.match(/<button[^>]*data-modal-cancel[^>]*>[^<]*</g) ?? [];
      expect(targets).toHaveLength(1);
      expect(targets[0]).toMatch(new RegExp(`>${cancelLabel}<$`));
    },
  );

  it('SquareTapMenu renders aria-modal="true" on its dialog element', () => {
    // SquareTapMenu positions itself against `window` during render; give it
    // a viewport for this one case only.
    vi.stubGlobal('window', { innerWidth: 1024, innerHeight: 768 });
    try {
      const html = renderToStaticMarkup(
        React.createElement(SquareTapMenu, {
          taskTitle: 'Read',
          x: 100,
          y: 100,
          onEdit: noop,
          onClose: noop,
        }),
      );
      const tags = dialogTags(html);
      expect(tags).toHaveLength(1);
      expect(tags[0]).toContain('aria-modal="true"');
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
