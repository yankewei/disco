import { describe, expect, it } from "vitest";
import { localizeSessionTitle, translate } from "./i18n.js";

describe("shared translations", () => {
  it("renders localized text with interpolation", () => {
    expect(translate("zh-CN", "modelCount", { count: 3 })).toBe("3 个模型");
    expect(translate("en-US", "modelCount", { count: 3 })).toBe("3 models");
  });

  it("localizes default session titles without changing user titles", () => {
    expect(localizeSessionTitle("新对话", "en-US")).toBe("New conversation");
    expect(localizeSessionTitle("Investigate auth", "zh-CN")).toBe(
      "Investigate auth",
    );
  });
});
