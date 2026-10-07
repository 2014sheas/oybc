import type { Task } from '@oybc/shared';
import { useTasks } from '../../hooks/useTasks';
import { KindTag } from './KindTag';
import { linkedKindTagProps } from './linkedKindTagProps';

export interface LinkedKindTagProps {
  /** The linked row (`sharedCounterId` set). */
  task: Task;
}

/**
 * LinkedKindTag — a linked row's Kind (spec §5): the kind tag + shared dots +
 * "{counter} · {all-time} all-time". Used by Board Edit's square sheet, Task
 * Detail's edit sheet and the pool row editor. iOS twin:
 * `KindTagView(linkedTask:root:)`.
 *
 * @returns The tag row.
 */
export function LinkedKindTag({ task }: LinkedKindTagProps): React.ReactElement {
  const pool = useTasks(task.userId);
  return <KindTag {...linkedKindTagProps(task, pool)} />;
}
