/**
 * Refuse content that looks like a credential before it reaches memory.
 *
 * Git keeps everything ever committed, and removing a leaked secret means
 * rewriting history on every clone. So a memory write that contains one is
 * rejected instead of stored. The patterns are specific token formats, not
 * guesses about "password-like" strings, so ordinary prose never trips them.
 */

const PATTERNS: Array<{ name: string; pattern: RegExp }> = [
  { name: "private key", pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: "AWS access key", pattern: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  {
    name: "GitHub token",
    pattern: /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b/,
  },
  { name: "Slack token", pattern: /\bxox[abposr]-[A-Za-z0-9-]{10,}/ },
  { name: "Anthropic key", pattern: /\bsk-ant-[A-Za-z0-9_-]{20,}/ },
  { name: "OpenAI key", pattern: /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}/ },
  { name: "Stripe secret key", pattern: /\b[rs]k_live_[A-Za-z0-9]{20,}/ },
  { name: "Google API key", pattern: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  {
    name: "credential in a URL",
    pattern: /\b[a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:[^\s/@]{8,}@[^\s/]+/i,
  },
];

export interface SecretFinding {
  name: string;
  line: number;
}

/** The first credential-looking match per line, 0-based line numbers. */
export function findSecrets(text: string): SecretFinding[] {
  const findings: SecretFinding[] = [];
  text.split("\n").forEach((line, index) => {
    for (const { name, pattern } of PATTERNS) {
      if (pattern.test(line)) {
        findings.push({ name, line: index });
        return;
      }
    }
  });
  return findings;
}

export class SecretInMemoryError extends Error {
  constructor(public readonly finding: SecretFinding) {
    super(
      `This looks like a ${finding.name}. Memory never stores credentials; remove it and try again.`,
    );
    this.name = "SecretInMemoryError";
  }
}

export function assertNoSecrets(text: string): void {
  const [finding] = findSecrets(text);
  if (finding) throw new SecretInMemoryError(finding);
}
