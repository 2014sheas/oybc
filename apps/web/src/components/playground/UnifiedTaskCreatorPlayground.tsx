// Phase 4.5+ will rewrite this playground to support the unified compound
// model. Until then, the file is gated to a placeholder so the web build
// passes — the legacy implementation referenced dropped CompositeTask /
// CompositeNode hierarchy, the dropped task_steps table, and the removed
// TaskType.PROGRESS enum value.

import React from 'react';

export function UnifiedTaskCreatorPlayground(): React.ReactElement {
  return (
    <div style={{ padding: 24, color: '#888', fontStyle: 'italic' }}>
      <strong>Awaiting Phase 5 rewrite.</strong>
      <p>
        This playground used the legacy progress + composite data model.
        It will be rewritten in a follow-up to use the unified compound
        task shape (Task with type='compound' + compoundChildren table).
      </p>
    </div>
  );
}
