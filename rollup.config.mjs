import ts from 'rollup-plugin-ts';

export default {
    input: 'src/index.ts',
    output: {
        file: 'dist/pocketbase.es.mjs',
        format: 'es',
        sourcemap: true,
    },
    plugins: [ts({ transpileOnly: true })],
    watch: { clearScreen: false },
};
