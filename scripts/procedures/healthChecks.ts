import { error, guardDurationAboveMinimum, ok, types as T } from "../deps.ts";

const url = "http://labelbase.embassy:8080";

export const health: T.ExpectedExports.health = {
  async "app-ui"(effects, duration) {
    // Ensure the starting duration is past a minimum
    const value = guardDurationAboveMinimum({ duration, minimumTime: 60_000 });
    if (value) {
      return value;
    }
    try {
      await effects.fetch(url);
      return ok;
    } catch (e) {
      console.warn(e);
      return error("Can not reach Labelbase");
    }
  },
};
