import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import * as dns from "node:dns/promises";
import { mkdirSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import { statePath } from "./paths";
import {
  CLIENT_METADATA_PATH,
  mcpOauthPublicRoutes,
  startMcpOauthFlow,
  supportsManualToken,
  validateManualMcpToken,
} from "./mcp-oauth";

describe("MCP OAuth client registration", () => {
  const realFetch = globalThis.fetch;
  let lookup: ReturnType<typeof spyOn<typeof dns, "lookup">>;
  const storePath = statePath(".opensession-mcp-oauth.json");

  beforeEach(() => {
    lookup = spyOn(dns, "lookup").mockImplementation((async () => [
      { address: "203.0.113.1", family: 4 },
    ]) as unknown as typeof dns.lookup);
    mkdirSync(dirname(storePath), { recursive: true });
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
    lookup.mockRestore();
    rmSync(storePath, { force: true });
  });

  test.each([
    { label: "absent", scopes: undefined, expected: null },
    { label: "empty", scopes: [], expected: null },
    {
      label: "advertised",
      scopes: ["mcp:connect", "offline_access"],
      expected: "mcp:connect offline_access",
    },
  ])(
    "uses only $label resource scopes, including on retry",
    async ({ label, scopes, expected }) => {
      let requests = 0;
      globalThis.fetch = (async (input: RequestInfo | URL) => {
        requests++;
        const url = String(input);
        if (
          url ===
          "https://mcp.example.test/.well-known/oauth-protected-resource"
        ) {
          return Response.json({
            resource: "https://mcp.example.test/mcp",
            authorization_servers: ["https://auth.example.test"],
            ...(scopes === undefined ? {} : { scopes_supported: scopes }),
          });
        }
        if (
          url ===
          "https://auth.example.test/.well-known/oauth-authorization-server"
        ) {
          return Response.json({
            issuer: "https://auth.example.test",
            authorization_endpoint: "https://auth.example.test/authorize",
            token_endpoint: "https://auth.example.test/token",
            registration_endpoint: "https://auth.example.test/register",
          });
        }
        if (url === "https://auth.example.test/register") {
          return Response.json({ client_id: "test-client" });
        }
        throw new Error(`Unexpected URL: ${url}`);
      }) as typeof fetch;

      // The failed first authorization leaves a cached registration. Retrying
      // must fix the scopes without requiring the user to clear that cache.
      for (let attempt = 0; attempt < 2; attempt++) {
        const { url } = await startMcpOauthFlow(
          `scopes-${label}`,
          "https://mcp.example.test/mcp",
        );
        const params = new URL(url).searchParams;
        expect(params.get("scope")).toBe(expected);
        expect(params.get("resource")).toBe("https://mcp.example.test/mcp");
        expect(params.get("client_id")).toBe("test-client");
        expect(params.get("code_challenge_method")).toBe("S256");
        expect(params.get("code_challenge")).toBeTruthy();
        expect(params.get("state")).toBeTruthy();
        expect(requests).toBe(5);
      }
    },
  );

  test("explains Figma's catalog restriction instead of reporting invalid JSON", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/.well-known/oauth-protected-resource")) {
        return Response.json({
          resource: "https://mcp.figma.com/mcp",
          authorization_servers: ["https://api.figma.com"],
          scopes_supported: ["mcp:connect"],
        });
      }
      if (
        url === "https://api.figma.com/.well-known/oauth-authorization-server"
      ) {
        return Response.json({
          issuer: "https://api.figma.com",
          authorization_endpoint: "https://www.figma.com/oauth/mcp",
          token_endpoint: "https://api.figma.com/v1/oauth/token",
          registration_endpoint: "https://api.figma.com/v1/oauth/mcp/register",
        });
      }
      if (url === "https://api.figma.com/v1/oauth/mcp/register") {
        return new Response("Forbidden", {
          status: 403,
          headers: { "Content-Type": "application/json" },
        });
      }
      throw new Error(`Unexpected URL: ${url}`);
    }) as unknown as typeof fetch;

    await expect(
      startMcpOauthFlow("Figma test", "https://mcp.figma.com/mcp"),
    ).rejects.toThrow(
      "Its remote MCP server accepts only clients listed in the Figma MCP Catalog",
    );
  });
});

describe("MCP OAuth client metadata document", () => {
  const realFetch = globalThis.fetch;
  const realIngress = process.env.OPENSESSION_INGRESS_BASE;
  let lookup: ReturnType<typeof spyOn<typeof dns, "lookup">>;
  const storePath = statePath(".opensession-mcp-oauth.json");
  const metadataUrl = `https://ingress.example.test${CLIENT_METADATA_PATH}`;

  beforeEach(() => {
    process.env.OPENSESSION_INGRESS_BASE = "https://ingress.example.test";
    lookup = spyOn(dns, "lookup").mockImplementation((async () => [
      { address: "203.0.113.1", family: 4 },
    ]) as unknown as typeof dns.lookup);
    mkdirSync(dirname(storePath), { recursive: true });
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
    if (realIngress === undefined) delete process.env.OPENSESSION_INGRESS_BASE;
    else process.env.OPENSESSION_INGRESS_BASE = realIngress;
    lookup.mockRestore();
    rmSync(storePath, { force: true });
  });

  function mockAuthServer(opts: { cimd: boolean; register: boolean }) {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (
        url.startsWith(
          "https://mcp.acme.test/.well-known/oauth-protected-resource",
        )
      )
        return Response.json({
          resource: "https://mcp.acme.test/mcp",
          authorization_servers: ["https://auth.acme.test/"],
        });
      if (
        url === "https://auth.acme.test/.well-known/oauth-authorization-server"
      )
        return Response.json({
          issuer: "https://auth.acme.test/",
          authorization_endpoint: "https://auth.acme.test/authorize",
          token_endpoint: "https://auth.acme.test/token",
          ...(opts.register
            ? { registration_endpoint: "https://auth.acme.test/register" }
            : {}),
          ...(opts.cimd ? { client_id_metadata_document_supported: true } : {}),
        });
      if (url === "https://auth.acme.test/register")
        return Response.json(
          { message: "dynamic client registration is disabled" },
          { status: 400 },
        );
      if (url === "https://mcp.acme.test/mcp")
        return new Response(null, { status: 401 });
      throw new Error(`Unexpected URL: ${url}`);
    }) as unknown as typeof fetch;
  }

  test.each([
    { label: "refuses", register: true },
    { label: "has no", register: false },
  ])(
    "uses the metadata document URL when the server $label registration",
    async ({ label, register }) => {
      mockAuthServer({ cimd: true, register });
      const { url } = await startMcpOauthFlow(
        `cimd-${label}`,
        "https://mcp.acme.test/mcp",
      );
      expect(new URL(url).searchParams.get("client_id")).toBe(metadataUrl);
    },
  );

  test("keeps the registration error when metadata documents are unsupported", async () => {
    mockAuthServer({ cimd: false, register: true });
    await expect(
      startMcpOauthFlow("cimd-none", "https://mcp.acme.test/mcp"),
    ).rejects.toThrow("dynamic client registration is disabled");
  });

  test("serves a public client document whose client_id is its own URL", async () => {
    const handler = mcpOauthPublicRoutes().get(`GET ${CLIENT_METADATA_PATH}`)!;
    const response = await handler(
      new Request(metadataUrl),
      new URL(metadataUrl),
    );
    const doc = await response.json();
    expect(doc.client_id).toBe(metadataUrl);
    expect(doc.token_endpoint_auth_method).toBe("none");
    expect(doc.redirect_uris[0]).toEndWith(
      "/api/connections/mcp-oauth/callback",
    );
  });
});

describe("manual MCP token providers", () => {
  const realFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  test("recognizes Vero as a token-connected provider", () => {
    expect(supportsManualToken("vero")).toBe(true);
  });

  test("validates a Vero key against the MCP initialize endpoint", async () => {
    let request: Request | undefined;
    globalThis.fetch = (async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      request = new Request(input, init);
      return Response.json({ jsonrpc: "2.0", id: 1, result: {} });
    }) as typeof fetch;

    await validateManualMcpToken("vero", "test-vero-key");

    expect(request?.url).toBe("https://api.getvero.com/mcp");
    expect(request?.method).toBe("POST");
    expect(request?.headers.get("authorization")).toBe("Bearer test-vero-key");
    expect(await request?.json()).toMatchObject({
      method: "initialize",
      params: { protocolVersion: "2025-03-26" },
    });
  });

  test("explains when Vero rejects a key", async () => {
    globalThis.fetch = (async () =>
      new Response("", { status: 401 })) as unknown as typeof fetch;

    await expect(validateManualMcpToken("vero", "bad-key")).rejects.toThrow(
      "Vero rejected that key",
    );
  });
});
