import type { StarlightPlugin } from '@astrojs/starlight/types';
import type { CopyButtonClientOptions, StarlightCopyButtonOptions } from './types';

export type { MarkdownTitleLevel, StarlightCopyButtonOptions } from './types';

const defaultOptions: CopyButtonClientOptions = {
	includeTitle: true,
	titleLevel: 1,
	label: 'Copy page',
	successLabel: 'Copied!',
	errorLabel: 'Copy failed',
	stateDuration: 2200,
	iconOnly: false,
};

export default function starlightCopyButton(opts: StarlightCopyButtonOptions = {}): StarlightPlugin {
	const options = normalizeOptions(opts);

	return {
		name: 'starlight-copy-button',
		hooks: {
			'config:setup'({ config, updateConfig, addIntegration }) {
				const customCss = config.customCss ?? [];
				if (!customCss.includes('starlight-copy-button/styles.css')) {
					updateConfig({
						customCss: [...customCss, 'starlight-copy-button/styles.css'],
					});
				}

				addIntegration({
					name: 'starlight-copy-button',
					hooks: {
						'astro:config:setup'({ injectScript, updateConfig }) {
							const modules = {
								'virtual:starlight-copy-button/options': `export const starlightCopyButtonOptions = ${JSON.stringify(
									options
								)}`,
							};
							/** Mapping names prefixed with `\0` to their original form. */
							const resolutionMap = Object.fromEntries(
								(Object.keys(modules) as (keyof typeof modules)[]).map((key) => [
									resolveVirtualModuleId(key),
									key,
								])
							);

							updateConfig({
								vite: {
									plugins: [
										{
											name: 'vite-plugin-starlight-copy-button',
											resolveId(id): string | void {
												if (id in modules) return resolveVirtualModuleId(id);
											},
											load(id): string | void {
												const resolution = resolutionMap[id];
												if (resolution) return modules[resolution];
											},
										},
									],
								},
							});

							injectScript(
								'page',
								`import { setupStarlightCopyButton } from 'starlight-copy-button/client';\nimport { starlightCopyButtonOptions } from 'virtual:starlight-copy-button/options';\nsetupStarlightCopyButton(starlightCopyButtonOptions);`
							);
						},
					},
				});
			},
		},
	};
}

function normalizeOptions(opts: StarlightCopyButtonOptions): CopyButtonClientOptions {
	return {
		includeTitle: opts.includeTitle ?? defaultOptions.includeTitle,
		titleLevel: normalizeTitleLevel(opts.titleLevel),
		label: opts.label ?? defaultOptions.label,
		successLabel: opts.successLabel ?? defaultOptions.successLabel,
		errorLabel: opts.errorLabel ?? defaultOptions.errorLabel,
		stateDuration: Math.max(400, opts.stateDuration ?? defaultOptions.stateDuration),
		iconOnly: opts.iconOnly ?? defaultOptions.iconOnly,
	};
}

function normalizeTitleLevel(
	level: StarlightCopyButtonOptions['titleLevel']
): CopyButtonClientOptions['titleLevel'] {
	if (typeof level === 'number' && Number.isInteger(level) && level >= 1 && level <= 6) {
		return level;
	}
	return defaultOptions.titleLevel;
}

function resolveVirtualModuleId<T extends string>(id: T): `\0${T}` {
	return `\0${id}`;
}
