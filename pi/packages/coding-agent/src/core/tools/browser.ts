import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { TextContent, ImageContent } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { getExperimentalToolSampling } from "../experimental.ts";
import type { ExtensionContext, ToolDefinition } from "../extensions/types.ts";
import { getTextOutput, str } from "./render-utils.ts";
import { wrapToolDefinition } from "./tool-definition-wrapper.ts";
import { readFile as fsReadFile } from "node:fs/promises";
import { Text } from "@earendil-works/pi-tui";

// Use any types for playwright to avoid module resolution errors when not installed
type Playwright = any;
type BrowserType = any;
type Browser = any;
type BrowserContext = any;
type Page = any;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const browserSchema = Type.Object(
	{
		action: Type.Union([
				Type.Literal("navigate"),
				Type.Literal("click"),
				Type.Literal("fill"),
				Type.Literal("read_text"),
				Type.Literal("screenshot"),
				Type.Literal("get_url"),
				Type.Literal("go_back"),
				Type.Literal("wait_for"),
				Type.Literal("eval"),
				Type.Literal("close"),
			]),
		url: Type.Optional(Type.String({ description: "URL to navigate to (required for action=navigate)" })),
		selector: Type.Optional(
			Type.String({
				description:
					"CSS selector for click/fill/read_text/wait_for. For click/fill, targets the element. For read_text, returns the element's text content. For wait_for, waits until the element exists in the DOM.",
			}),
		),
		text: Type.Optional(Type.String({ description: "Text to type into a field (required for action=fill)" })),
		timeout: Type.Optional(
			Type.Number({
				description: "Timeout in seconds for this action (default 30s). Use for slow pages or waits.",
			}),
		),
		js: Type.Optional(Type.String({ description: "JavaScript expression to eval in the page context (action=eval). Returns the result." })),
		fullPage: Type.Optional(Type.Boolean({ description: "For screenshot: capture the full scrollable page instead of just the viewport." })),
	},
	{ additionalProperties: false },
);

export type BrowserToolInput = {
	readonly action: "navigate" | "click" | "fill" | "read_text" | "screenshot" | "get_url" | "go_back" | "wait_for" | "eval" | "close";
	readonly url?: string;
	readonly selector?: string;
	readonly text?: string;
	readonly timeout?: number;
	readonly js?: string;
	readonly fullPage?: boolean;
};

export interface BrowserToolDetails {
	/** Screenshot file path when action=screenshot produced one */
	screenshotPath?: string;
	/** Current page URL after the action */
	url?: string;
	/** Page title after the action */
	title?: string;
	/** Whether a new page/browser was opened for this call */
	opened?: boolean;
}

// Lazy playwright module — loaded on first use so the tool definition is cheap to import
// even when playwright is not installed (the execute() will raise a clear error).
let pw: any = null;
let pwLoadPromise: Promise<any> | null = null;

async function loadPlaywright(): Promise<any> {
	if (pw) return pw;
	if (pwLoadPromise) return pwLoadPromise;
	pwLoadPromise = (async () => {
		try {
			pw = await import("playwright");
			return pw;
		} catch {
			pw = null;
			return null;
		}
	})();
	return pwLoadPromise;
}

// Per-tool browser instance. Created on first navigate (or any action that needs it),
// reused across calls in the same tool lifetime, closed on close action or tool disposal.
// The tool definition is long-lived per session, so this gives the agent a persistent
// browsing session across multiple browser calls — the normal expectation for a browsing task.
let browserInstance: any = null;
let browserContext: any = null;
let currentPage: any = null;
let browserError: string | null = null;

async function ensureBrowser(): Promise<any> {
	if (browserError) throw new Error(browserError);
	if (browserInstance) return browserInstance;
	const playwright = await loadPlaywright();
	if (!playwright) {
		browserError = "playwright is not installed. Run: npm install playwright && npx playwright install chromium";
		throw new Error(browserError);
	}
	try {
		const chromium = playwright.chromium;
		if (!chromium) throw new Error("playwright.chromium is unavailable");
		const browser = await chromium.launch({
			headless: true,
			args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
		});
		browserInstance = browser;
		return browser;
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		browserError = `Failed to launch browser: ${message}`;
		throw new Error(browserError);
	}
}

async function ensureContext(): Promise<any> {
	if (browserContext) return browserContext;
	const browser = await ensureBrowser();
	browserContext = await browser.newContext({
		viewport: { width: 1280, height: 900 },
		locale: "en-US",
		javaScriptEnabled: true,
	});
	return browserContext;
}

async function ensurePage(): Promise<any> {
	if (currentPage) return currentPage;
	const context = await ensureContext();
	currentPage = await context.newPage();
	return currentPage;
}

function resolveTimeout(timeout?: number): number {
	if (timeout === undefined) return 30_000;
	if (!Number.isFinite(timeout) || timeout <= 0) return 30_000;
	// Cap at 5 minutes to keep unattended runs from hanging indefinitely on a stuck page.
	return Math.min(timeout * 1000, 300_000);
}

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export const browserToolSystemPromptContribution = {
	snippet: "Control a headless browser: open pages, click, fill forms, screenshot, read text",
	guidelines: [
		"Use browser navigate to open a page before clicking or reading.",
		"Use browser wait_for with a CSS selector after navigate or click to wait for dynamic content.",
		"Use browser screenshot to capture the current page state — useful for debugging or confirming a form submission.",
		"Use browser read_text to extract visible text from a specific element (e.g. a confirmation message).",
		"Use browser eval to run arbitrary JavaScript in the page when CSS selectors aren't enough (e.g. read the page HTML via document.documentElement.outerHTML).",
		"Call browser close when the browsing task is done to free resources.",
	],
} as const;

export function createBrowserToolDefinition(
	cwd: string,
	_options?: {},
): ToolDefinition<typeof browserSchema, BrowserToolDetails | undefined> {
	return {
		name: "browser",
		label: "browser",
		description: `Control a headless Chromium browser. Actions: navigate (open a URL), click (click a CSS selector), fill (type text into a CSS selector), read_text (get an element's visible text), screenshot (capture the page), get_url (current URL), go_back (browser back), wait_for (wait for a CSS selector to appear), eval (run JavaScript in the page), close (close the browser).

Use browser to do web-based work unattended: open signup pages, fill forms, submit, screenshot the confirmation, read text from the page.`,
		promptSnippet: browserToolSystemPromptContribution.snippet,
		promptGuidelines: [...browserToolSystemPromptContribution.guidelines],
		parameters: browserSchema,
		constrainedSampling: getExperimentalToolSampling(),
		executionMode: "sequential",
		async execute(
			_toolCallId,
			{ action, url, selector, text, timeout, js, fullPage }: BrowserToolInput,
			signal?: AbortSignal,
			_onUpdate?,
			_ctx?: ExtensionContext,
		) {
			const timeoutMs = resolveTimeout(timeout);
			if (signal?.aborted) throw new Error("Operation aborted");

			try {
				switch (action) {
					case "navigate": {
						if (!url) throw new Error("browser navigate requires a url");
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						await page.goto(url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
						const title = await page.title();
						const currentUrl = page.url();
						return {
							content: [
								{
									type: "text",
									text: `Navigated to ${url}\nTitle: ${title}\nURL: ${currentUrl}`,
								},
							],
							details: { url: currentUrl, title, opened: !currentPage },
						};
					}

					case "click": {
						if (!selector) throw new Error("browser click requires a selector");
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						await page.waitForSelector(selector, { state: "visible", timeout: timeoutMs });
						await page.click(selector);
						// Give the page a moment to react.
						await page.waitForTimeout(300);
						const title = await page.title();
						const currentUrl = page.url();
						return {
							content: [{ type: "text", text: `Clicked ${selector}\nTitle: ${title}\nURL: ${currentUrl}` }],
							details: { url: currentUrl, title },
						};
					}

					case "fill": {
						if (!selector) throw new Error("browser fill requires a selector");
						if (text === undefined) throw new Error("browser fill requires text");
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						await page.waitForSelector(selector, { state: "visible", timeout: timeoutMs });
						await page.fill(selector, text);
					const value =await page.$eval(selector, (el: any) => {
						return el?.value ?? "(no value)";
					})
							.catch(() => "(could not read value back)");
						return {
							content: [{ type: "text", text: `Filled ${selector} with ${text}\nValue now: ${value}` }],
							details: { url: page.url(), title: await page.title() },
						};
					}

					case "read_text": {
						if (!selector) throw new Error("browser read_text requires a selector");
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						await page.waitForSelector(selector, { state: "visible", timeout: timeoutMs });
						const text = await page.$eval(selector, (el: any) => el?.textContent ?? "(no text)").catch(() => "(no text)");
						return {
							content: [{ type: "text", text: `Text at ${selector}:\n${text}` }],
							details: { url: page.url(), title: await page.title() },
						};
					}

					case "screenshot": {
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						const path = `/tmp/vertus-browser-${Date.now()}.png`;
						await page.screenshot({ path, fullPage: fullPage ?? false, timeout: timeoutMs });
				return {
					content: [
						{ type: "text", text: `Screenshot saved to ${path}` },
						{ type: "image", data: Buffer.from(await fsReadFile(path)).toString("base64"), mimeType: "image/png" } as ImageContent,
					],
					details: { screenshotPath: path, url: page.url(), title: await page.title() },
				};
					}

					case "get_url": {
						const page = await ensurePage();
						const currentUrl = page.url();
						const title = await page.title();
						return {
							content: [{ type: "text", text: `URL: ${currentUrl}\nTitle: ${title}` }],
							details: { url: currentUrl, title },
						};
					}

					case "go_back": {
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						await page.goBack({ timeout: timeoutMs }).catch(() => {
							throw new Error("browser go_back failed (no history or timeout)");
						});
						const currentUrl = page.url();
						const title = await page.title();
						return {
							content: [{ type: "text", text: `Went back\nURL: ${currentUrl}\nTitle: ${title}` }],
							details: { url: currentUrl, title },
						};
					}

					case "wait_for": {
						if (!selector) throw new Error("browser wait_for requires a selector");
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
						await page.waitForSelector(selector, { state: "visible", timeout: timeoutMs });
						return {
							content: [{ type: "text", text: `Waited for ${selector} — found` }],
							details: { url: page.url(), title: await page.title() },
						};
					}

					case "eval": {
						if (!js) throw new Error("browser eval requires js");
						const page = await ensurePage();
						await page.setDefaultTimeout(timeoutMs);
					const result = await page.evaluate((expression: string) => {
						return eval(expression);
					}, js);
						const resultText =
							result === undefined
								? "undefined"
								: typeof result === "string"
									? result
									: JSON.stringify(result, null, 2);
						return {
							content: [{ type: "text", text: `eval(${js}) =>\n${resultText}` }],
							details: { url: page.url(), title: await page.title() },
						};
					}

					case "close": {
						if (currentPage) {
							try { await currentPage.close(); } catch {}
							currentPage = null;
						}
						if (browserContext) {
							try { await browserContext.close(); } catch {}
							browserContext = null;
						}
						// leave browserInstance open so a new context can reuse it, but drop the context
						return {
							content: [{ type: "text", text: "Browser closed (context released). A new navigate will open a fresh context." }],
							details: {},
						};
					}

					default:
						throw new Error(`Unknown browser action: ${action}`);
				}
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				return {
					content: [{ type: "text", text: `browser ${action} failed: ${message}` }],
					details: { url: currentPage?.url(), title: currentPage?.title() },
				};
			}
		},
		renderCall(args, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const action = str(args?.action);
			const label = action === "navigate" ? `browser ${action} ${str(args?.url)}` : action === "eval" ? `browser eval …` : `browser ${action}${str(args?.selector) ? ` ${str(args?.selector)}` : ""}`;
			text.setText(theme.fg("toolTitle", theme.bold(label)));
			return text;
		},
		renderResult(result, options, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const output = getTextOutput(result, false);
			const details = result.details as BrowserToolDetails | undefined;
			let textContent = output;
			if (details?.screenshotPath) {
				textContent += `\n\nScreenshot: ${details.screenshotPath}`;
			}
			if (!options.expanded && !context.isError) {
				text.setText("");
			} else {
				text.setText(textContent);
			}
			return text;
		},
	};
}

export function createBrowserTool(cwd: string, options?: {}): AgentTool<typeof browserSchema> {
	return wrapToolDefinition(createBrowserToolDefinition(cwd, options));
}
