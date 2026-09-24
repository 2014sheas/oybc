import styles from './CounterWriteError.module.css';

interface CounterWriteErrorProps {
  /** The error to show, or null to render nothing. */
  message: string | null;
}

/**
 * CounterWriteError — the inline error line the Counters Hub and Detail show
 * when a log or undo write fails (see `counterWriteFeedback.ts`). Announced via
 * `role="alert"`; renders nothing when there is no error.
 */
export function CounterWriteError({ message }: CounterWriteErrorProps): React.ReactElement | null {
  if (!message) return null;
  return (
    <p className={styles.error} role="alert">
      {message}
    </p>
  );
}
