/**
 * CompoundChild — one parent-child link in a compound task's structure.
 *
 * Replaces both `task_steps` (for progress) and `composite_nodes` leaves (for
 * composite). The parent compound's operator + threshold + isOrdered fields
 * live on the Task row itself (see `Task` in ./task.ts).
 *
 * The child can be ANY Task — primitive (normal/counting) or another
 * compound. Nesting is natural: a compound's children may themselves
 * resolve to compound rows whose own children are evaluated recursively.
 */
export interface CompoundChild {
  // Identity
  id: string;                    // UUID (client-generated)
  compoundTaskId: string;        // FK to tasks (the parent compound)
  childTaskId: string;           // FK to tasks (the child — any type, including nested compound)

  // Ordering
  childIndex: number;            // 0-based; honored when parent.isOrdered

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete
  deletedAt?: string;            // ISO8601
}

/**
 * CompoundChild creation input.
 */
export interface CreateCompoundChildInput {
  compoundTaskId: string;
  childTaskId: string;
  childIndex: number;
}
