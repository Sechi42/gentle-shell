import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { WindowsSessionPresenceRegistry, WindowsSessionTransportHost, parseWindowsHostFrame } from "../lib/windows-session-transport.ts";

const endpoint = "\\\\.\\pipe\\gentle-pi-0123456789abcdef0123456789abcdef";
const record = (index: number, wide = false) => ({ version: 1, sessionId: `s${String(index).padStart(wide ? 127 : 4, "0")}`, endpoint, createdAt: wide ? Number.MAX_SAFE_INTEGER : 1 });
const cursor = (index: number) => index.toString(16).padStart(32, "0");
const frame = (result: unknown) => JSON.stringify({ requestId: "page-1", ok: true, result });

// Real host request/decoder plumbing; only the PowerShell child is synthetic.
async function fixture(reply: (request: Record<string, unknown>, index: number) => unknown) {
	const calls: Record<string, unknown>[] = [];
	const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), stderr: new EventEmitter(), stdin: Object.assign(new EventEmitter(), {
		writable: true, end() {}, write(line: string, callback: () => void) {
			const request = JSON.parse(line);
			const result = request.operation === "start" ? { state: "partial" } : reply(request, calls.push(request) - 1);
			callback();
			if (result !== undefined) child.stdout.emit("data", Buffer.from(JSON.stringify({ requestId: request.requestId, ...(result === "invalid" ? { ok: false, error: "invalid" } : { ok: true, result }) }) + "\n"));
			return true;
		},
	}), kill() { child.emit("close", 1, null); return true; } });
	const host = new WindowsSessionTransportHost({ spawnProcess: () => child as never });
	await host.start();
	const Registry = WindowsSessionPresenceRegistry as unknown as { new(host: WindowsSessionTransportHost): WindowsSessionPresenceRegistry };
	return { registry: new Registry(host), calls, finish: () => child.emit("close", 0, null) };
}

test("Windows page parser adds exact bounded pages without changing legacy frames", () => {
	for (const next of [null, cursor(1)]) assert.deepEqual(parseWindowsHostFrame(frame({ records: [record(0)], cursor: next })).result, { records: [record(0)], cursor: next });
	assert.deepEqual(parseWindowsHostFrame(frame({ records: [record(0)] })).result, { records: [record(0)] });
	for (const result of [
		{ records: [], cursor: "A".repeat(32) }, { records: [], cursor: "0".repeat(31) },
		{ records: [], cursor: 1 }, { records: [], cursor: cursor(1) + "\n" }, { records: [], cursor: null, extra: true },
		{ records: Array.from({ length: 33 }, (_, i) => record(i)), cursor: null },
		{ records: [{ ...record(0), extra: true }], cursor: null },
		{ records: [{ ...record(0), createdAt: -1 }], cursor: null },
	]) assert.throws(() => parseWindowsHostFrame(frame(result)), /invalid Windows transport frame/);
	assert.throws(() => parseWindowsHostFrame(frame({ records: [], cursor: null }) + " ".repeat(16_384)), /invalid Windows transport frame/);
});

test("Windows public list collects 90 ordinal winners with identical exclusion on every page", async () => {
	const expected = Array.from({ length: 90 }, (_, i) => record(i));
	for (const candidates of [false, true]) {
		const f = await fixture((request, i) => {
			assert.equal(request.operation, "list-page");
			assert.equal(request.excludeSessionId, "self");
			assert.equal(request.cursor, i === 0 ? null : cursor(i));
			return { records: expected.slice(i * 32, (i + 1) * 32), cursor: i === 2 ? null : cursor(i + 1) };
		});
		try {
			assert.deepEqual(candidates ? await f.registry.list("self") : await f.registry.listActivations("self"), candidates ? expected.map(({ sessionId }) => ({ sessionId, reachability: "unknown" })) : expected);
			assert.equal(f.calls.length, 3);
		} finally { f.finish(); }
	}
});

test("Windows public list preserves empty and small-list public contracts", async () => {
	for (const count of [0, 1, 32, 64]) {
		const expected = Array.from({ length: count }, (_, i) => record(i));
		const f = await fixture((_request, i) => ({ records: expected.slice(i * 32, (i + 1) * 32).map(({ version, sessionId, endpoint, createdAt }) => ({ createdAt, endpoint, sessionId, version })), cursor: (i + 1) * 32 < count ? cursor(i + 1) : null }));
		try { assert.deepEqual(await f.registry.listActivations(), expected); }
		finally { f.finish(); }
	}
	const f = await fixture(() => assert.fail("invalid exclusion must not reach the helper"));
	try { await assert.rejects(f.registry.list(""), { code: "io_error" }); assert.equal(f.calls.length, 0); }
	finally { f.finish(); }
});

test("Windows public list refuses malicious or incompatible pages without partial output or retry", async () => {
	const cases = [
		[{ records: [record(0)], cursor: cursor(1) }, { records: [record(1)], cursor: cursor(2) }, { records: [record(2)], cursor: cursor(1) }],
		[{ records: [record(0)], cursor: cursor(1) }, { records: [record(1)], cursor: cursor(1) }], // replay
		[{ records: [record(0)], cursor: cursor(1) }, { records: [], cursor: cursor(2) }],
		[{ records: [record(0)], cursor: cursor(1) }, { records: [record(0)], cursor: null }], // duplicate
		[{ records: [record(1)], cursor: cursor(1) }, { records: [record(0)], cursor: null }], // regression
		[{ records: [record(0)], cursor: cursor(1) }, { records: [record(1)] }], // legacy midstream
		[{ records: [record(0)], cursor: cursor(1) }, "invalid"], // expiry/rejection
		[{ records: [record(0)], cursor: cursor(1) }, { records: [record(1)], cursor: "bad" }],
		[{ records: [record(0)], cursor: cursor(1) }, { records: [], cursor: null }],
		[{ records: [record(0)] }], ["invalid"], [{ state: "partial" }],
		[{ records: [record(0)], cursor: null }], // excluded peer
	];
	for (const replies of cases) {
		const f = await fixture((_request, i) => replies[i]);
		try {
			await assert.rejects(f.registry.list(replies.length === 1 && typeof replies[0] === "object" && "cursor" in replies[0] ? record(0).sessionId : undefined), { code: "io_error", message: "transport I/O failed" });
			assert.equal(f.calls.length, replies.length);
			assert.ok(f.calls.every((request) => request.operation === "list-page"), "no fallback or mutation RPC");
		} finally { f.finish(); }
	}
});

test("Windows public list bounds records, canonical bytes and page count, accepting exact limits", async () => {
	const byteLimitCount = Math.floor(524_288 / Buffer.byteLength(JSON.stringify(record(0, true))));
	for (const [count, wide, succeeds, expectedCalls] of [[4096, false, true, 128], [4097, false, false, 128], [byteLimitCount, true, true, Math.ceil(byteLimitCount / 32)], [byteLimitCount + 1, true, false, Math.ceil((byteLimitCount + 1) / 32)]] as const) {
		const records = Array.from({ length: count }, (_, i) => record(i, wide));
		const f = await fixture((_request, i) => ({ records: records.slice(i * 32, (i + 1) * 32), cursor: (i + 1) * 32 < count ? cursor(i + 1) : null }));
		try {
			if (succeeds) assert.deepEqual(await f.registry.listActivations(), records);
			else await assert.rejects(f.registry.listActivations(), { code: "io_error" });
			assert.equal(f.calls.length, expectedCalls);
		} finally { f.finish(); }
	}
	// One record per page would evade the record cap, but must not evade the page cap.
	const f = await fixture((_request, i) => ({ records: [record(i)], cursor: cursor(i + 1) }));
	try { await assert.rejects(f.registry.list(), { code: "io_error" }); assert.equal(f.calls.length, 128); }
	finally { f.finish(); }
});

test("Windows public list has one cooperative 2000ms deadline, not a fresh budget per page", async (t) => {
	t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
	let advance = false;
	const f = await fixture((_request, i) => {
		if (advance) t.mock.timers.tick(1_000);
		advance = true;
		return { records: [record(i)], cursor: cursor(i + 1) };
	});
	try { await assert.rejects(f.registry.list(), { code: "io_error" }); assert.equal(f.calls.length, 3); }
	finally { f.finish(); }
	const stalled = await fixture(() => undefined);
	try {
		const listing = stalled.registry.list();
		t.mock.timers.tick(2_000);
		await assert.rejects(listing, { code: "io_error" });
		assert.equal(stalled.calls.length, 1);
	} finally { stalled.finish(); }
});
