// Phase 4.5 / Phase 5 will replace this with a CompoundDetailPanel that
// renders a compound task's children using allCompoundChildren +
// compoundChildrenByCompound from the unified useTaskLibrary hook.
//
// The legacy CompositeDerivationPanel read CompositeNode[] from the
// dropped composite_nodes table; the data isn't there anymore.
//
// This stub keeps the type signature compatible with consumers (CreatePage)
// so the build passes; rendering returns null until Phase 4.5 lands.

import type { Task, CompoundChild } from '@oybc/shared';

export interface CompositeDerivationPanelProps {
  compositeTask: Task;
  compoundChildren: CompoundChild[];
  taskMap: Record<string, Task>;
  onAddLeafToPool?: (taskId: string, title: string, type: string) => void;
  isInPool?: (taskId: string) => boolean;
}

export function CompositeDerivationPanel(_props: CompositeDerivationPanelProps): React.ReactElement {
  return (
    <div style={{ fontSize: '0.85rem', color: '#888', padding: '12px', fontStyle: 'italic' }}>
      Compound task inspector — awaiting Phase 4.5 rewrite. The legacy
      composite-tree panel consumed schema that was dropped in v5.
    </div>
  );
}
