import { healthUtil, types as T } from "../deps.ts";

export const health: T.ExpectedExports.health = {
  "app-ui": healthUtil.checkWebUrl("http://labelbase.embassy:8080"),  
};
