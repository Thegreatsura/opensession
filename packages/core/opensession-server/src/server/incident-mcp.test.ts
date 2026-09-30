import { describe, expect, test } from "bun:test";
import { declaringSessionReport, type IncidentMcpDeps } from "./incident-mcp";

const deps = (declared = true): IncidentMcpDeps => ({
  declaringSessionFor: async () =>
    declared
      ? {
          sessionId: "os-triage",
          incidentId: "01M3SBWM38AS5GGECBX13SZBS7",
          reference: "INC-105",
          at: "2026-09-30T14:35:53Z",
        }
      : null,
  sessionTitle: () => "Buy now does nothing",
  sessionLink: (id) => `https://os.example.test/session/${id}`,
  evidence: async () => "Evidence (server-computed):\nPR: open #7857",
  transcriptTail: async () => [
    { id: "1", type: "user", content: "ticket text", timestamp: "" },
    { id: "2", type: "assistant", content: "Found the cause.", timestamp: "" },
    { id: "3", type: "tool_use", content: "bash", timestamp: "" },
    { id: "4", type: "assistant", content: "Opened #7857.", timestamp: "" },
  ],
});

describe("declaringSessionReport", () => {
  test("returns the declaring session's link, evidence and findings", async () => {
    const text = await declaringSessionReport("#INC-105", ["INC-105"], deps());
    expect(text).toContain("os-triage (Buy now does nothing)");
    expect(text).toContain("https://os.example.test/session/os-triage");
    expect(text).toContain("PR: open #7857");
    expect(text).toContain("Found the cause.");
    expect(text).toContain("Opened #7857.");
    expect(text).not.toContain("ticket text");
  });

  test("answers only for the run's own incident", async () => {
    const text = await declaringSessionReport("INC-104", ["INC-105"], deps());
    expect(text).toContain("can only look up the incident it was started for");
    expect(text).not.toContain("os-triage");
  });

  test("says so when no Open Session session declared it", async () => {
    expect(
      await declaringSessionReport("INC-105", ["INC-105"], deps(false)),
    ).toContain("No Open Session session declared INC-105");
  });
});
