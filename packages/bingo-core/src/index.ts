/**
 * @oybc/bingo-core
 *
 * Pure bingo game math shared by OYBC (Do) and Play OYBC.
 * ONLY primitives-in/primitives-out pure functions — no domain entities
 * (Task/Board/BoardTask), no platform code, no side effects. This purity
 * is what lets the same detection code run in browsers, and Node
 * (Cloud Functions) for server-authoritative win validation.
 */
export * from './bingoDetection';
export * from './shuffle';
export * from './centerSquare';
export * from './placement';
export * from './constants';
