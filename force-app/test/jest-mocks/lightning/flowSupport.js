export const FlowNavigationNextEvent = class extends CustomEvent {
  constructor() {
    super("navigate");
  }
};
export const FlowNavigationBackEvent = class extends CustomEvent {
  constructor() {
    super("navigateback");
  }
};
export const FlowNavigationFinishEvent = class extends CustomEvent {
  constructor() {
    super("finish");
  }
};
export const FlowNavigationPauseEvent = class extends CustomEvent {
  constructor() {
    super("pause");
  }
};
