// Real Pi SDK, real watcher/drain, local controlled provider. No external requests.
// Invoked by fm-pi-primary-live-e2e.test.sh in synthetic-only mode.
import { cpSync, mkdirSync, readFileSync, writeFileSync, existsSync, symlinkSync, renameSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [root, lab, pkg, scenario] = process.argv.slice(2);
const repo = `${lab}/code`, home = `${lab}/home`, state = `${home}/state`, agentDir = `${lab}/agent`;
for (const dir of [repo, state, `${home}/config`, agentDir, `${lab}/sessions`, `${lab}/claims`, `${lab}/fakebin`]) mkdirSync(dir, { recursive: true, mode: 0o700 });
cpSync(`${root}/bin`, `${repo}/bin`, { recursive: true });
mkdirSync(`${repo}/.pi/extensions/lib`, { recursive: true });
cpSync(`${root}/.pi/extensions/fm-primary-pi-watch.ts`, `${repo}/.pi/extensions/fm-primary-pi-watch.ts`);
cpSync(`${root}/.pi/extensions/lib`, `${repo}/.pi/extensions/lib`, { recursive: true });
mkdirSync(`${repo}/node_modules/@earendil-works`, { recursive: true });
symlinkSync(pkg, `${repo}/node_modules/@earendil-works/pi-coding-agent`);
for (const name of ['@earendil-works/pi-tui', 'typebox']) symlinkSync(`${pkg}/node_modules/${name}`, `${repo}/node_modules/${name}`);
writeFileSync(`${lab}/fakebin/tmux`, '#!/usr/bin/env bash\ncase "$1" in capture-pane) echo fixture-idle;; *) exit 0;; esac\n', { mode: 0o755 });
Object.assign(process.env, {
  FM_HOME: home, FM_ROOT_OVERRIDE: repo, FM_STATE_OVERRIDE: state, FM_CONFIG_OVERRIDE: `${home}/config`,
  FM_DATA_OVERRIDE: `${home}/data`, FM_WAKE_QUEUE: `${state}/.wake-queue`, FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`,
  FM_PROCEVENT_CLAIM_ROOT: `${lab}/claims`, FM_POLL: '1', FM_SIGNAL_GRACE: '1',
  FM_CHECK_INTERVAL: '999999', FM_HEARTBEAT: '999999', FM_SECONDMATE_LIVENESS_SECS: '99999999',
  FM_HOME_SUMMARY_INTERVAL: '99999999', FM_PI_WATCH_HEALTH_POLL_MS: '200',
  FM_GUARD_GRACE: '6', FM_PI_ARM_READY_TIMEOUT_MS: '5000',
  FM_WATCH_REARM_RETRY_LIMIT: '1', FM_WATCH_REARM_RETRY_BASE_MS: '100', FM_WATCH_REARM_RETRY_MAX_MS: '100',
  PI_CODING_AGENT_DIR: agentDir, PATH: `${lab}/fakebin:${process.env.PATH}`,
});
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
writeFileSync(`${state}/home-summary.json`, '{}\n');
// Metadata is synthetic and its only backend command resolves to fakebin/tmux.
writeFileSync(`${state}/fixture.meta`, `window=fixture:worker\nbackend=tmux\nharness=pi\nkind=scout\nproject=${lab}/project\n`);
if (scenario === 'cannot-start') writeFileSync(`${state}/early.status`, 'done: SYNTHETIC_DONE finished before monitoring started\n');
if (scenario === 'contended') {
  mkdirSync(`${state}/procevent`);
  mkdirSync(`${lab}/claims/legacy.lock`);
  writeFileSync(`${lab}/claims/legacy.lock/pid`, `${process.pid}\n`);
  writeFileSync(`${lab}/claims/legacy.claim`, `${home}\n${process.pid}\nlegacy\nwrong-identity\n`);
}
if (scenario === 'hang' || scenario === 'cannot-start') {
  renameSync(`${repo}/bin/fm-watch-arm.sh`, `${repo}/bin/fm-watch-arm-real.sh`);
  writeFileSync(`${repo}/bin/fm-watch-arm.sh`, scenario === 'cannot-start'
    ? '#!/usr/bin/env bash\necho "watcher: FAILED - synthetic cannot-start"\nexit 1\n'
    : `#!/usr/bin/env bash
. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
mkdir -p "$STATE/.watch.lock"
printf '%s\\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s/bin/fm-watch.sh\\n' "$FM_ROOT_OVERRIDE" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
touch "$STATE/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
`, { mode: 0o755 });
}
writeFileSync(`${agentDir}/models.json`, JSON.stringify({ providers: { 'fm-health': {
  baseUrl: 'https://fm-health.invalid/v1', apiKey: 'local-fixture', api: 'openai-completions',
  models: [{ id: 'synthetic', name: 'Synthetic', reasoning: false, input: ['text'], contextWindow: 128000, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
} } }));
const pkgUrl = pathToFileURL(`${pkg}/dist/index.js`).href;
const { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } = await import(pkgUrl);
const timeline = [], finals = [];
let requests = 0;
const text = content => typeof content === 'string' ? content : (content ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n');
// This provider supplies deterministic tool choices, not a stub Pi or delivery API.
// It only summarizes a worker outcome after the real bash tool ran the real drain.
globalThis.fetch = async (input, options) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith('https://fm-health.invalid/')) throw new Error(`unexpected network request: ${url}`);
  const body = JSON.parse(options.body);
  const messages = body.messages;
  const lastUser = messages.findLastIndex(m => m.role === 'user');
  const toolMessages = messages.slice(lastUser + 1).filter(m => m.role === 'tool');
  const drained = toolMessages.map(m => text(m.content)).join('\n');
  let delta, finish;
  if (toolMessages.length === 0) {
    delta = { role: 'assistant', tool_calls: [{ index: 0, id: `drain-${++requests}`, type: 'function', function: {
      name: 'bash', arguments: JSON.stringify({ command: `bash '${repo}/bin/fm-wake-drain.sh'` }),
    } }] }; finish = 'tool_calls';
  } else {
    const ack = drained.match(/WAKE_ACK_REQUIRED: after handling completes run ([^\n]+)/)?.[1];
    if (ack && toolMessages.length === 1) {
      delta = { role: 'assistant', tool_calls: [{ index: 0, id: `ack-${++requests}`, type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command: ack }) } }] };
      finish = 'tool_calls';
    } else {
      const outcome = drained.includes('SYNTHETIC_ACCESS')
        ? 'Synthetic check blocked: authenticated browser unavailable; live settings remain unverified. Reconnect the authenticated browser.'
        : drained.includes('SYNTHETIC_DONE') ? 'Synthetic check completed; the result is ready for review.'
        : 'Monitoring unavailable; current worker records checked.';
      delta = { role: 'assistant', content: outcome }; finish = 'stop';
    }
  }
  const chunk = (d, reason) => `data: ${JSON.stringify({ id: 'health-fixture', object: 'chat.completion.chunk', created: 1, model: 'synthetic', choices: [{ index: 0, delta: d, finish_reason: reason }] })}\n\n`;
  return new Response(chunk(delta, null) + chunk({}, finish) + 'data: [DONE]\n\n', { status: 200, headers: { 'content-type': 'text/event-stream' } });
};
const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
const loader = new DefaultResourceLoader({ cwd: repo, agentDir, settingsManager: settings,
  additionalExtensionPaths: [`${repo}/.pi/extensions/fm-primary-pi-watch.ts`], noExtensions: true,
  noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  systemPromptOverride: () => 'Synthetic monitoring test. Drain notifications and report actual worker outcomes.',
});
await loader.reload();
const runtime = await ModelRuntime.create({ authPath: `${agentDir}/auth.json`, modelsPath: `${agentDir}/models.json` });
const { session } = await createAgentSession({ cwd: repo, agentDir, modelRuntime: runtime,
  model: runtime.getModel('fm-health', 'synthetic'), settingsManager: settings, resourceLoader: loader,
  sessionManager: SessionManager.create(repo, `${lab}/sessions`), tools: ['bash', 'fm_watch_arm_pi'],
});
session.subscribe(event => {
  if (event.type === 'message_end') {
    timeline.push({ time: Date.now(), role: event.message.role, text: text(event.message.content),
      ...(event.message.role === 'toolResult' ? { isError: event.message.isError } : {}) });
    if (event.message.role === 'assistant' && event.message.stopReason === 'stop') finals.push(text(event.message.content));
  }
});
const waitFor = async (f, label) => {
  for (let i = 0; i < 600; i++) { if (f()) return; await new Promise(r => setTimeout(r, 100)); }
  throw new Error(`${scenario}: timeout ${label}; ${JSON.stringify(timeline)}`);
};
try {
  const arm = session.getToolDefinition('fm_watch_arm_pi');
  if (!arm) throw new Error('Pi did not load the real watcher extension');
  await arm.execute('initial-arm', {}, undefined, undefined, {});
  if (scenario === 'hang' || scenario === 'cannot-start') {
    await waitFor(() => finals.some(t => t.includes(scenario === 'cannot-start' ? 'Synthetic check completed' : 'Monitoring unavailable')), 'idle outage final');
    await session.agent.waitForIdle();
  } else {
    await waitFor(() => existsSync(`${state}/.last-watcher-beat`), 'first beacon');
  }
  const started = Date.now();
  const done = scenario === 'done';
  timeline.push({ time: started, role: 'producer', text: done ? 'done' : 'blocked' });
  writeFileSync(`${state}/fixture.status`, done ? 'done: SYNTHETIC_DONE check complete\n' : 'blocked: [key=access] SYNTHETIC_ACCESS authenticated browser unavailable\n');
  const expected = done ? 'Synthetic check completed' : 'Synthetic check blocked';
  await waitFor(() => finals.some(t => t.includes(expected)), 'substantive main final without user query');
  await session.agent.waitForIdle();
  const elapsed = Date.now() - started;
  const persisted = readFileSync(session.sessionFile, 'utf8');
  if (!persisted.includes(expected)) throw new Error('final absent from real Pi JSONL');
  if (!timeline.some(e => e.role === 'toolResult' && e.text.includes(done ? 'SYNTHETIC_DONE' : 'SYNTHETIC_ACCESS'))) throw new Error('provider answered without drain evidence');
  if (timeline.some(e => e.role === 'toolResult' && e.isError)) throw new Error(`tool execution failed: ${JSON.stringify(timeline)}`);
  if (existsSync(`${state}/.wake-queue`) && readFileSync(`${state}/.wake-queue`, 'utf8').trim()) throw new Error('wake queue still contains unacknowledged notifications');
  if (scenario === 'contended') {
    process.kill(process.pid, 0);
    if (readFileSync(`${lab}/claims/legacy.lock/pid`, 'utf8').trim() !== String(process.pid)) throw new Error('unrelated source lock changed');
  }
  if (scenario === 'hang') {
    const repair = await arm.execute('repair', {}, undefined, undefined, {});
    if (repair.details.ok) throw new Error('stalled child claimed healthy on explicit repair');
  }
  writeFileSync(`${lab}/timeline.json`, JSON.stringify(timeline, null, 2));
  console.log(`ok - real Pi ${scenario}: idle notification, real drain, persisted substantive final (${elapsed}ms)`);
} finally {
  // The session runtime's shutdown event retires only this fixture's arm.
  await session.extensionRunner?.emit({ type: 'session_shutdown', reason: 'quit' });
  session.dispose();
}
