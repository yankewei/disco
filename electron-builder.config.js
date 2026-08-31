const updateUrl = process.env.DISCO_UPDATE_URL;
const signingIdentity = process.env.CSC_NAME ?? null;

const publish = updateUrl
  ? [{ provider: "generic", url: updateUrl }]
  : undefined;

export default {
  appId: "ai.disco.desktop",
  productName: "Disco",
  files: ["dist-node/**", "dist-renderer/**", "package.json"],
  publish: publish ?? null,
  mac: {
    category: "public.app-category.developer-tools",
    identity: signingIdentity,
    target: ["dmg", "zip"],
    // These platform bundles are shipped together and selected by process.arch at runtime.
    x64ArchFiles: "{**/claude,**/rg,**/better-sqlite3/prebuilds/*.node}",
  },
  dmg: {
    sign: false,
  },
};
