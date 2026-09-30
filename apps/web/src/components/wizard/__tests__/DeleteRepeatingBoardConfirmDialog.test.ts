import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  DeleteRepeatingBoardConfirmDialog,
  type DeleteRepeatingBoardConfirmDialogProps,
} from '../DeleteRepeatingBoardConfirmDialog';

/**
 * The editor's delete confirm (Profile reorg PR3 — Delete moved off the
 * Board-settings roster row into the wizard's edit mode): it names the
 * repeating board, states that already-created boards survive, offers both
 * choices, announces itself as an alert dialog, and never uses the
 * "template"/"spawn" vocabulary the copy rule forbids.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo (see
 * `RemoveSourceConfirmDialog.test.ts`), so focus/Escape behaviour is not
 * covered here.
 */

function render(over: Partial<DeleteRepeatingBoardConfirmDialogProps> = {}): string {
  const props: DeleteRepeatingBoardConfirmDialogProps = {
    boardName: 'Morning Routine',
    busy: false,
    onConfirm: () => {},
    onCancel: () => {},
    ...over,
  };
  return renderToStaticMarkup(React.createElement(DeleteRepeatingBoardConfirmDialog, props));
}

describe('DeleteRepeatingBoardConfirmDialog', () => {
  it('names the repeating board in the heading', () => {
    expect(render()).toContain('Delete &quot;Morning Routine&quot;?');
  });

  it('states that boards already created from it survive', () => {
    expect(render()).toContain('Boards already created from it will not be deleted.');
  });

  it('offers Cancel and Delete, and announces itself as an alert dialog', () => {
    const html = render();
    expect(html).toContain('role="alertdialog"');
    expect(html).toContain('>Cancel</button>');
    expect(html).toContain('>Delete</button>');
  });

  it('disables both actions and relabels Delete while busy', () => {
    const html = render({ busy: true });
    expect(html).toContain('Deleting…');
    expect((html.match(/disabled=""/g) ?? []).length).toBe(2);
  });

  it('never uses the forbidden "template" / "spawn" vocabulary', () => {
    const html = render();
    expect(html).not.toMatch(/template/i);
    expect(html).not.toMatch(/spawn/i);
  });
});
