export type MarkdownTitleLevel = 1 | 2 | 3 | 4 | 5 | 6;

/** Runtime configuration passed to the client script. */
export interface CopyButtonClientOptions {
	includeTitle: boolean;
	titleLevel: MarkdownTitleLevel;
	label: string;
	successLabel: string;
	errorLabel: string;
	stateDuration: number;
	iconOnly: boolean;
}

/** Plugin user options. */
export interface StarlightCopyButtonOptions {
	/**
	 * Include a Markdown heading for the current page title at the top of copied output.
	 *
	 * @default true
	 */
	includeTitle?: boolean;

	/**
	 * Markdown heading level used when `includeTitle` is enabled.
	 *
	 * @default 1
	 */
	titleLevel?: MarkdownTitleLevel;

	/**
	 * Idle-state button label.
	 *
	 * @default 'Copy page'
	 */
	label?: string;

	/**
	 * Success-state button label shown after copying.
	 *
	 * @default 'Copied!'
	 */
	successLabel?: string;

	/**
	 * Error-state button label shown if copying fails.
	 *
	 * @default 'Copy failed'
	 */
	errorLabel?: string;

	/**
	 * Milliseconds to show success/error states before returning to idle.
	 *
	 * @default 2200
	 */
	stateDuration?: number;

	/**
	 * Render an icon-only button.
	 *
	 * @default false
	 */
	iconOnly?: boolean;
}
