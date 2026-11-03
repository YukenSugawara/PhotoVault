const sharp = require("sharp");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const assets = path.join(root, "PhotoVault", "Resources", "Assets.xcassets");
const styles = [
  ["standard", "AppIcon"],
  ["indigo", "AppIconIndigo"],
  ["rose", "AppIconRose"],
  ["emerald", "AppIconEmerald"],
  ["sunset", "AppIconSunset"],
  ["sky", "AppIconSky"],
];

// iPhone・iPad用の1024pxアイコンだけを登録します。
// macOS向けのサイズやDock用画像を生成しないため、公開対象を誤って広げません。
const appIconContents = {
  images: [
    { filename: "Icon-1024.png", idiom: "universal", platform: "ios", size: "1024x1024" },
  ],
  info: { author: "xcode", version: 1 },
};

async function run() {
  for (const [sourceName, appIconName] of styles) {
    const source = path.join(__dirname, `${sourceName}.svg`);
    const appIconDirectory = path.join(assets, `${appIconName}.appiconset`);
    fs.mkdirSync(appIconDirectory, { recursive: true });

    // 色違いを増やすときも、一覧への1行追加とSVGだけで全画像を再生成できます。
    fs.writeFileSync(
      path.join(appIconDirectory, "Contents.json"),
      `${JSON.stringify(appIconContents, null, 2)}\n`,
    );
    await sharp(source)
      .resize(1024, 1024)
      // App Storeのアイコン検証に合わせ、透過チャンネルを残しません。
      .flatten({ background: "#000000" })
      .png()
      .toFile(path.join(appIconDirectory, "Icon-1024.png"));
  }
}

run().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
