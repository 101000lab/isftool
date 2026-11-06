# isftool 設計書

ISF (Interactive Shader Format) シェーダーを VDMX6 Plus と同じ経路 (GLSL 4.00 → SPIR-V → Metal) で検査し, 描画し, GPU 時間を測る macOS 用の CLI.
この文書だけを読んで別セッションが実装を始められることを目指す. 既に手元で確かめたことは「検証済み」, 確かめていない推測は「未検証」と書き分ける.

## 0. 現状 (2026-11-06)

- M0 は完了. M1 は check, info, dump (`uniforms` を除く) を実装し, 完了条件 0 から 7 をテストか手元の実行で確かめた (9 章の M1 に結果を書いた). 未実装は `dump uniforms` と `~/Library/Caches/isftool/` の変換結果キャッシュ.
- テストは `swift test`. Command Line Tools には XCTest が無いので swift-testing (`import Testing`) で書いた. ISFGLSLGenerator と組み込みの glslang / SPIRV-Cross と Metal を実際に通す統合テスト (`Tests/ISFKitTests/IntegrationTests.swift`) は, Metal のデバイスが無ければ無効になる.
- M2 は `render` で 1 パスのシェーダーを PNG にするところまで実装し, WebGL の preview と見比べた (9 章の M2).
- M3 は複数パス, 持続バッファ, IMPORTED 画像を描けるようにし, `--frames` を足した (9 章の M3).
- M4 は `bench` と 6 章の Level モードを実装し, `render` にも `--levels`, `--recording`, `--level-pattern` を足した (9 章の M4). 完了条件は 4 つとも満たした (4 は例のシェーダーを差し替えた). `--images` はまだ無い.
- 6 章のモードの与え方を `--feed-envelope` と `--feed-envelope-pattern` にまとめ, envelope をバイナリに組み込んだ (6 章, 2026-11-06). `--levels`, `--recording`, `--level-pattern`, `--modes` は外した.
- M5 は README を足した (9 章の M5). 複数のシェーダーをまとめて測るスクリプトは呼び出し元のリポジトリに置き, isftool は特定のリポジトリに依存しない.
- glslang と SPIRV-Cross は, VDMX6 Plus 6.1.3.6 が同梱する版と同じ upstream のコミットを submodule にして組み込んだ (2.6). Homebrew の glslang と spirv-cross は要らなくなった.
- 4 章の変換経路は一時ディレクトリで試しただけで, ファイルは残していない.
- VDMX が使っているとみられる VIDVOX の公開実装を見つけ, ソースを読んだ (2.5). GLSL の組み立ては自前で書かず, その実装 (ISFGLSLGenerator) を組み込む方針に変えた. 3 章の写しは, その実装と VDMX が一致することの証拠として残している.
- 決めたことと分かったことは全てこの文書にある. 実装中に新しく分かったことは, この文書の該当箇所を「検証済み」に書き換えていく.

## 1. 目的と動機

- 呼び出し元は VDMX6 Plus 用の ISF シェーダー集 (非公開のリポジトリ). シェーダーの確認には WebGL のブラウザ preview を使っているが, VDMX とは別の経路なので次の 2 つが見えない.
  1. VDMX でだけ失敗するコンパイルエラー. `layout` を変数名や入力名にしたシェーダー (line_space, thin_barcode) が preview では通り, VDMX で `syntax error, unexpected LAYOUT` で失敗した. 関数名 `vertex` を持つシェーダー (super_polygons) は VDMX の Metal 変換で `expected unqualified-id` になった.
  2. シェーダーごとの GPU コスト. ライブで 16 レイヤー全てに ISF クリップを読み込むと出力が大きく落ち, 見えている 1 枚だけにすると 120 fps だった. VDMX はクリップが入ったレイヤーを透明度 0 でも毎フレーム描く. どのシェーダーが重いかを VDMX を使わずに順位付けしたい.
- 最終形は単独の CLI `isftool`. 呼び出し元に固有の決まり (Level 入力の命名) はフラグで差し替えられる既定値として持ち, リポジトリから切り離しても使えるようにする.
- 想定する使い方は 2 つ.
  - 全シェーダーをまとめて検査, 計測して重い順に並べる.
  - 1 本のシェーダーを何度も計測しながらチューニングする (前回との差を見る).

## 2. 環境 (検証済み, 2026-11-04)

| 項目 | 値 |
|---|---|
| マシン | Apple M4 Pro, Metal 3 |
| OS | macOS 15 (Darwin 24.6, arm64) |
| Swift | 6.1.2. Xcode は無く Command Line Tools のみ (`/Library/Developer/CommandLineTools`) |
| glslang | 14.3.0 (`Vendor/glslang`, upstream の `8590f62c`). 組み込み (2.6) |
| SPIRV-Cross | `Vendor/SPIRV-Cross`, upstream の `66363ac7`. 組み込み (2.6) |

- Metal の実行時コンパイル `MTLDevice.makeLibrary(source:options:)` は Command Line Tools だけで動く (検証済み. swiftc で作った小さな実行ファイルで MSL をコンパイルできた).
- glslang と SPIRV-Cross はライブラリとして isftool に静的にリンクする (2.6). M4 までは Homebrew の版を外部コマンドとして呼んでいた.

## 2.5 VIDVOX の公開実装 (検証済み, 2026-11-04 にソースを読んだ)

VDMX の開発元 VIDVOX の作者 (GitHub の mrRay) が, ISF を Metal で描く実装を公開している. 手元に ghq で clone してある.

| リポジトリ | 読んだ版 | 中身 |
|---|---|---|
| `github.com/mrRay/ISFMSLKit` | `3aa9355` | ISF を Metal で描く Mac 用フレームワーク (Objective-C++). GLSL を作り, SPIR-V を経て MSL に変換し, Metal で描く. コンパイル結果を PINCache でディスクに保存する |
| `github.com/mrRay/ISFGLSLGenerator` | `2b5507b` (ISFMSLKit が submodule で参照する版と同じ) | ISF を読んで GLSL を組み立てる C++ ライブラリ. BSD 3-Clause. 依存は同梱のヘッダーだけ (nlohmann json, exprtk) |
| `github.com/mrRay/glslang` の `GLSLangValidatorLib` ブランチ | `StandAlone/GLSLangValidatorLib.cpp` だけ `gh` で読んだ | glslang の CLI をライブラリにしたもの |
| `github.com/mrRay/SPIRV-Cross` の `SPIRVCrossLib` ブランチ | `SPIRVCrossLib.cpp` だけ `gh` で読んだ | SPIRV-Cross の CLI をライブラリにしたもの |

VDMX6 がこれ (かその社内版) を使っていると判断した根拠.

- VDMX のエラー画面の見出し `Error Compiling GLSL Fragment Shader to SPIR-V:` と `Error Compiling GLSL Vertex Shader to SPIR-V:` が, ISFMSLKit の `ISFMSLTranspilerError.mm` の文字列と一字一句同じ.
- 3 章の写し (VDMX のエラー画面の GLSL) が, ISFGLSLGenerator の出力の形 (前置き, `VVISF_UNIFORMS`, `VVSAMPLER_2DBYPIXEL`, `gl_FragCoord` の置き換え) と一致する.

ソースから分かったこと.

- **GLSL の組み立て**: `ISFDoc::generateShaderSource(&frag, &vert, VVISF::GLVersion_4, true)`. 最後の `true` は「入力を UBO (`VVISF_UNIFORMS`) にまとめる」. IMG 系の関数の書き換え, `IMG_THIS_PIXEL` 用に頂点シェーダーで座標を計算して渡す処理, `.vs` の扱い, uniform の並びとオフセットの計算は全てこの関数の中にある. よって isftool はこのソースを組み込んで呼ぶ (8 章).
- **glslang に渡す引数** (`GLSLangValidatorLib.cpp`): `-G --amb --aml --stdin -S frag` (頂点は `-S vert`). `--amb` は `--auto-map-bindings`, `--aml` は `--auto-map-locations`.
- **SPIRV-Cross に渡す引数** (`SPIRVCrossLib.cpp`): `--rename-entry-point main <新しい名前> frag --msl -` (頂点は `vert`). MSL のバージョン指定も `--msl-decoration-binding` も無い. Metal の引数の番号は SPIRV-Cross が自動で振る.
- **関数名**: `VV<ファイル名>VertFunc` と `VV<ファイル名>FragFunc`. ファイル名 (拡張子なし) の英数字以外は `_` に置き換える (`ISFMSLFuncSignature.mm` の `ISFMSLEntryPointNamesForPath`).
- **解決できない uniform の検査**: シェーダー本体が自分で `uniform` を宣言すると, ホストが値を渡せない引数が MSL に残る. ISFMSLKit はこれを失敗として扱う (`ISFMSLFindUnboundArgs`). isftool の check でも同じ検査をする.
- **uniform の詰め方**: 先頭に `ISFShaderRenderInfo` (48 バイト. `PASSINDEX TIME RENDERSIZE[2] DATE[4] TIMEDELTA FRAMEINDEX PADDING_INFO[2]`), 画像ごとに `ISFShaderImgInfo` (32 バイト. `rect[4] size[2] flip PADDING_IMG`), 入力の値が続く. 各入力と各バッファのオフセットは `generateShaderSource` が `offsetInBuffer()` に書き込み, 全体の大きさを返す (`VVISF_Base.hpp`, `ISFAttr.hpp`, `ISFPassTarget.hpp`). ISFMSLKit はこの大きさを 48 の倍数に切り上げたバッファをパスごとに `newBufferWithBytes` で作り, 頂点とフラグメントの両方に渡す.
  - 実装して分かったこと (検証済み). `offsetInBuffer()` は `ISFShaderRenderInfo` の後ろからの相対値で, ISFMSLScene は `sizeof(ISFShaderRenderInfo)` を足した位置に書く. 値は `generateShaderSource` ではなく ISFDoc を作ったときに決まる. UBO モードの `generateShaderSource` が `outUBOSize` に返すのは 48 のままで使えないので, ISFMSLKit と同じく `getMaxUBOSize()` を使う. 切り上げは `maxUBOSize + (48 - maxUBOSize % 48)` で, ちょうど 48 の倍数でも 1 ブロック足される (line_space は 104 バイトで, バッファは 144 バイト).
- **`_X_flip`**: 普通のテクスチャで 1. コメントは「GLSL は左下原点で読むが Metal は左上原点なので, ここで反転する」(`ISFMSLScene.mm`). `rect` はテクスチャの中の使う範囲を正規化した値, `size` はその範囲のピクセル数.
- **パスのテクスチャ**: 8 bit は `BGRA8`, `FLOAT` は RGBA の float (`VVMTLPool` の `bgra8TexSized` と `rgbaFloatTexSized`). パスの大きさが変わったら作り直す.
- **ロードアクション**: カスタムの頂点シェーダーがあるときだけクリア, それ以外は `DontCare`. つまり持続でないバッファの初期内容は保証されない.
- **サンプラー**: 正規化座標, 線形補間, 端はクランプ.
- **頂点データ**: 解像度ごとに作った四角形のバッファを, 頂点関数が使う最大のバッファ番号 + 1 の番号に置く.

手元の Homebrew 版で, 上の glslang と SPIRV-Cross の引数をそのまま使って line_space を変換し, Metal でコンパイルできた (検証済み). 関数名 `vertex` を持つ自作の小さなシェーダーは, それでも Homebrew の SPIRV-Cross が `vertex0` に改名して通った. 一方 VDMX では `vec2 vertex(float column, float row)` を持つ super_polygons が `expected unqualified-id` で落ちた. 理由は分かっていない. VIDVOX の SPIRV-Cross の版の違いかもしれないが, SPIRV-Cross は以前から MSL の予約語を改名しているので, 版の違いだけとは言い切れない. 本物の super_polygons (修正前) を M1 で isftool に通して確かめる. どちらの結果でも, Metal の予約語は isftool が自前で検査する (7.2).

M1 で確かめた結果 (検証済み). 本物の super_polygons (修正前) も, 字句検査を外すと Homebrew の SPIRV-Cross が `vertex0` に改名し, Metal でもコンパイルできた. 字句検査を入れると `stage: lint` で失敗する (統合テストに両方を残した). VDMX で落ちた理由は SPIRV-Cross の版の違いだった (2026-11-04, 検証済み). VDMX と同じ同梱の dylib (10 章) を使い捨てのプログラムから呼ぶと, 同じ GLSL から `vertex` を改名しない MSL が出て, Metal が VDMX と同じ `expected unqualified-id` で落とした. 違いは `vertex` の 5 行だけだった. 同じ比べ方で呼び出し元のシェーダー 400 本近くとテストのフィクスチャのうち, glslang を通る 408 本の fragment の MSL を比べると, この 1 本以外は 1 文字も違わなかった. `layout` を使う 2 本は, 同梱の glslang でも Homebrew と同じく構文エラーになった.

ISFMSLKit の `extern/` には, VIDVOX がビルドした glslang と SPIRV-Cross の dylib (arm64 と x86_64, macOS 15 以上) が同梱されている. VDMX6 Plus 6.1.3.6 はこれと同じものを載せている (10 章). 配布物には使わず, 組み込んだ版 (2.6) の出力を確かめる基準にだけ使った.


## 2.6 glslang と SPIRV-Cross の組み込み (検証済み, 2026-11-05)

- fork は upstream のコミットに CLI のラッパーを足しただけだった. SPIRV-Cross の `SPIRVCrossLib` ブランチは upstream の `66363ac7` (2024-07-30) に `SPIRVCrossLib.cpp` などのファイルを足しただけで, 既存のソースには手を入れていない. glslang の `GLSLangValidatorLib` ブランチは upstream の `8590f62c` (2024-07-30, 版は 14.3.0) にラッパーを足し, ビルドの設定で `ENABLE_OPT` を切っている (spirv-opt を使わない). bundled の dylib の `glslang::GetVersion()` も 14.3.0 を返した.
- isftool は upstream のこの 2 つのコミットを `Vendor/glslang` と `Vendor/SPIRV-Cross` に submodule で置き, SwiftPM の C++ target (`CGLSLang`, `CSPIRVCross`) としてビルドする. fork のコードは使わない (ライセンスの出どころを upstream だけにするためと, ラッパーの作りのため).
- fork のラッパーは CLI の `main()` に引数の配列を渡し, 標準出力をプロセスごと差し替えて読む. グローバルな状態を持つのでロックで 1 本ずつしか通らず, 差し替え中は isftool 自身の出力も奪われる. そこで `Sources/CToolchain` に C の API を置き, 次のように呼ぶ.
  - glslang は `StandAlone.cpp` の `CompileAndLinkShaderUnits` が `-G --amb --aml --stdin -S <stage>` で通る道を, 同じ順で API に写した (`glslang.cpp`). 入力の名前は `stdin` にするので, エラーは VDMX と同じ `ERROR: stdin:<行>:` になる. ログはラッパーと同じく, CLI が標準出力に出すもの (ファイル名の行を除く) にする.
  - SPIRV-Cross は CLI の `main.cpp` を翻訳単位ごと取り込み, `compile_iteration` を `--rename-entry-point main <名前> <stage> --msl` と同じ引数で呼ぶ (`spirv_cross.cpp`). CLI は引数の既定値から CompilerMSL の設定を数十個決めるので, 写さずに CLI のコードをそのまま使う.
  - CMake が作る `glslang/build_info.h` (14.3.0) と `glslang/glsl_intrinsic_header.h` は `Sources/CToolchain/generated/` に置いた.
- 確かめたこと. 呼び出し元の全シェーダーとテストのフィクスチャを, isftool と bundled の dylib (使い捨てのプログラムから呼んだ) の両方に通し, vert と frag の 816 の stage で SPIR-V と MSL が 1 バイトまで一致した. `layout` を使う 2 本はどちらも glslang で同じエラーになった. テストは並列に流しても通る.
- 効果. 160 本ほどの check がデバッグビルドで約 3 秒になった (外部コマンドでは 1 本に約 0.3 秒かかっていた). `vertex` を持つ super_polygons (修正前) は Metal の段で VDMX と同じ `expected unqualified-id` になる.
- `--glslang` と `--spirv-cross` は消した. `isftool --version` は組み込んだ版と, 合わせた VDMX の版 (VDMX6 Plus 6.1.3.6) を出す.
- 字句検査 (`stage: lint`, `--no-lint`) は外した (2026-11-05, ユーザーの判断). Homebrew の版との違いを補うために入れたものだった. 同じ版を組み込んだ今は Metal が VDMX と同じものを落とすので, 字句検査が落とせるのは Metal を通ったシェーダー, つまり VDMX でも動くシェーダーだけになる.

## 3. VDMX が組み立てる GLSL (検証済みの写し)

VDMX のエラー画面に出た, line_space.fs と thin_barcode.fs から VDMX が生成した GLSL をそのまま写す. isftool は 2.5 の ISFGLSLGenerator を組み込むので, この形を自分で組み立てる必要は無い. この章は, 組み込んだ生成器の出力が VDMX と一致するかを確かめるための見本として使う (M1 の完了条件). 空白はエラー画面の表示で崩れているので整えた.

### 3.1 頂点シェーダー (シェーダーに .vs が無いとき)

```glsl
#version 400

precision highp float;
precision highp int;

in vec4		VERTEXDATA;
void isf_vertShaderInit();

out vec2		isf_FragNormCoord;
out vec2		isf_FragCoord;
uniform sampler2D		lineState;
layout (std140) uniform VVISF_UNIFORMS	{
	int		PASSINDEX;
	float		TIME;
	vec2		RENDERSIZE;
	vec4		DATE;
	float		TIMEDELTA;
	int		FRAMEINDEX;
	vec2		PADDING_INFO;
	vec4		_lineState_imgRect;
	vec2		_lineState_imgSize;
	bool		_lineState_flip;
	int		_lineState_padding;
	float		Items;
	float		Growth;
	bool		Clear;
	float		Speed;
	float		Opacity;
	float		Width;
};

void main(void)	{
	isf_vertShaderInit();
}

void isf_vertShaderInit(void)	{
	//	gl_Position should be equal to gl_ProjectionMatrix * gl_ModelViewMatrix * gl_Vertex
	mat4			projectionMatrix = mat4(2./RENDERSIZE.x, 0., 0., -1.,
		0., -2./RENDERSIZE.y, 0., 1.,
		0., 0., -1., 0.,
		0., 0., 0., 1.);
	gl_Position = VERTEXDATA * projectionMatrix;
	isf_FragNormCoord = vec2((gl_Position.x+1.0)/2.0, ((gl_Position.y+1.0)/2.0));
	isf_FragCoord = floor(isf_FragNormCoord * RENDERSIZE);
}
```

### 3.2 フラグメントシェーダーの前置き

```glsl
#version 400

precision highp float;
precision highp int;

#define gl_FragColor isf_FragColor
out vec4 gl_FragColor;
in vec2		isf_FragNormCoord;
in vec2		isf_FragCoord;
uniform sampler2D		lineState;
layout (std140) uniform VVISF_UNIFORMS	{ ...頂点と同じ... };

vec4 VVSAMPLER_2DBYPIXEL(sampler2D inSampler, vec4 inSamplerImgRect, vec2 inSamplerImgSize, bool inSamplerFlip, vec2 inLoc)	{
	return (inSamplerFlip)
		? texture		(inSampler,vec2(((inLoc.x/inSamplerImgSize.x*inSamplerImgRect.z)+inSamplerImgRect.x), (inSamplerImgRect.w-(inLoc.y/inSamplerImgSize.y*inSamplerImgRect.w)+inSamplerImgRect.y)))
		: texture		(inSampler,vec2(((inLoc.x/inSamplerImgSize.x*inSamplerImgRect.z)+inSamplerImgRect.x), ((inLoc.y/inSamplerImgSize.y*inSamplerImgRect.w)+inSamplerImgRect.y)));
}
vec4 VVSAMPLER_2DBYNORM(sampler2D inSampler, vec4 inSamplerImgRect, vec2 inSamplerImgSize, bool inSamplerFlip, vec2 normLoc)	{
	vec4		returnMe = VVSAMPLER_2DBYPIXEL(		inSampler,inSamplerImgRect,inSamplerImgSize,inSamplerFlip,vec2(normLoc.x*inSamplerImgSize.x, normLoc.y*inSamplerImgSize.y));
	return returnMe;
}
```

この後にシェーダー本体 (メタデータの `/*{ ... }*/` を除いた部分) が続く.

### 3.3 本体の書き換え

| 元 | VDMX の生成物 | 根拠 |
|---|---|---|
| `IMG_PIXEL(lineState, vec2(1.5, 0.5))` | `VVSAMPLER_2DBYPIXEL(lineState, _lineState_imgRect, _lineState_imgSize, (_lineState_flip), vec2(1.5, 0.5))` | VDMX の画面と ISFGLSLGenerator のソースの両方 |
| `gl_FragCoord.x` | `isf_FragCoord.x` | VDMX の画面とソースの両方. ソースのコメントは「Metal に変換するので y 軸が反転するため」 |
| `IMG_NORM_PIXEL` / `IMG_THIS_PIXEL` / `IMG_THIS_NORM_PIXEL` / `IMG_SIZE` | `ISFDoc.cpp` の `generateShaderSource` を参照 | ソース. `IMG_THIS_PIXEL` は頂点シェーダー側で座標を計算して渡す |

- 書き換えは ISFGLSLGenerator がするので, isftool は自前で書き換えない.
- `gl_FragCoord` は `isf_FragCoord` に置き換わるが, 値は `gl_FragCoord` と同じ画素の中心 (x + 0.5, y + 0.5) になる. `isf_FragCoord` は頂点シェーダーの出力で, 頂点 (四隅) では `isf_FragNormCoord * RENDERSIZE` がちょうど 0 か W / H なので `floor` は何もしない. その値が面の中で線形に補間され, 画素の中心で評価される. 半画素のずれは無いので, 描画側で補正しないこと.

### 3.4 uniform ブロックの並び (検証済み)

1. 固定の 7 個: `int PASSINDEX; float TIME; vec2 RENDERSIZE; vec4 DATE; float TIMEDELTA; int FRAMEINDEX; vec2 PADDING_INFO;`
2. 画像ごと: `vec4 _X_imgRect; vec2 _X_imgSize; bool _X_flip; int _X_padding;`
3. INPUTS を定義順に. 型の対応は `float`→`float`, `long`→`int`, `bool`→`bool`, `event`→`bool`, `color`→`vec4`, `point2D`→`vec2`. `image` と `audio` と `audioFFT` は `uniform sampler2D` と 2 の 4 項目を持つ.
- 正確な順序とオフセットは ISFGLSLGenerator の `_assembleShaderSource_VarDeclarations` が決める. isftool はそれが書き込む `offsetInBuffer()` を使い, 自分で計算しない.
- `thin_barcode.fs` では入力の `long` が `int layout;` としてブロックに入っていた. 入力名がそのままメンバー名になるので, 予約語の入力名も glslang で検出できる.
- サンプラーはブロックの外に `uniform sampler2D X;` として並ぶ.

## 4. 手元で確かめた変換経路 (検証済み)

3 の形の line_space を使い, VIDVOX と同じ引数 (2.5) で全段が通った.

```sh
glslang -G --amb --aml -S vert -o vert.spv isf.vert     # VIDVOX は --stdin で渡す
glslang -G --amb --aml -S frag -o frag.spv isf.frag
spirv-cross frag.spv --rename-entry-point main VVline_spaceFragFunc frag --msl --output frag.metal
spirv-cross vert.spv --rename-entry-point main VVline_spaceVertFunc vert --msl --output vert.metal
spirv-cross frag.spv --reflect                          # JSON. 調べるときだけ (VIDVOX は使わない)
# Swift から MTLDevice.makeLibrary(source:) で frag.metal と vert.metal をコンパイル (OK)
```

分かったこと.

- `-G` は OpenGL 意味論の SPIR-V. `precision` 修飾子や std140 のブロックをそのまま受け付けた.
- 頂点とフラグメントは別々にコンパイルする (VIDVOX も段ごとに別の関数).
- `--msl-decoration-binding` を付けないと, Metal の引数の番号は SPIRV-Cross が段ごと, 資源の種類ごとに 0 から振り直す. 例えばフラグメントは `constant VVISF_UNIFORMS& [[buffer(0)]]`, `texture2d<float> lineState [[texture(0)]]`, `sampler lineStateSmplr [[sampler(0)]]` になった. 同じシェーダーを `--msl-decoration-binding` 付きで変換したときは uniform が `[[buffer(1)]]` だった.
- **よって Metal の引数の番号は, 生成された MSL の関数の宣言を文字列解析して名前ごとに読む** (ISFMSLKit の `ISFMSLParseFuncSignature` と同じ). `--reflect` の `binding` は glslang が振った SPIR-V の番号で, VIDVOX の引数で変換した MSL の番号とは一致しない. `--reflect` を番号に使うと, エラーにならないまま別の場所に値が入り, 絵が壊れる. `--reflect` はオフセットの確認とデバッグにだけ使う. テクスチャが複数ある (持続バッファ, IMPORTED, image 入力) シェーダーでは, 名前ごとの解析で並び順が決まる.
- `bool` は 4 バイトの `uint` になる. uniform の値の位置は ISFGLSLGenerator のオフセットを使う. `--reflect` のオフセットが `48 + offsetInBuffer()` と一致することを line_space で確かめ, 統合テストに残した (検証済み).
- glslang に `--stdin` で渡すと, エラーは標準出力に `ERROR: stdin:111: ...` の形で出る. この番号は VDMX のエラー画面と同じ (line_space の修正前の版で 111). `-H` (SPIR-V の逆アセンブル) は `-G` と併用でき, 一覧は標準出力に, 入力名の `stdin` は標準エラーに出る (検証済み).
- 頂点の入力は `VERTEXDATA [[attribute(0)]]`.
- 予約語の再現.
  - 変数名 `layout`: glslang で `syntax error, unexpected LAYOUT, expecting COMMA or SEMICOLON`. VDMX と同じ文言 (検証済み).
  - 関数名 `vertex`: 自作の小さなシェーダーでは, Homebrew の spirv-cross が VIDVOX と同じ引数でも `vertex0` に改名して, Metal でも通ってしまった. VDMX で落ちたのは, VDMX の古い SPIRV-Cross が `vertex` を改名しないため (2.5). 組み込んだ同じ版の SPIRV-Cross も改名しないので, isftool も Metal の段で同じく落とす (2.6).

## 5. CLI 仕様

```
isftool check  <shader.fs> [--json]
isftool render <shader.fs> --out <dir|file.png> [--frames N] [--at SECONDS] [描画オプション]
isftool bench  <shader.fs> [描画オプション] [計測オプション]
isftool info   <shader.fs> [--size WxH]                 # 短い要約
isftool dump   <shader.fs> <what> [--size WxH] [--set NAME=VALUE]...
isftool --version
```

どのサブコマンドもシェーダーは 1 本だけ受け取る. 何本も通すときは `xargs -n 1` などで 1 本ずつ呼ぶ (2026-11-05, ユーザーの判断. M4 までは `check` と `bench` が複数本と `--from` を受け付けたが, xargs と比べて利点がほとんど無かった). シェーダーをまたいだ順位は, 結果のファイル (7.5) から作る.

`info` は画面に収まる要約だけを出す. 生成物の全文は `dump` で 1 つずつ標準出力に出す (数百行になるシェーダーもあり, まとめて出すと要約が流れて見えなくなるため).

`info` が出すもの.

- 入力の一覧 (名前, 型, DEFAULT / MIN / MAX, Level 入力とみなしたか)
- パス (TARGET, 持続か, `--size` で評価した大きさ)
- IMPORTED 画像の解決後のパス
- uniform の配置 (`VVISF_UNIFORMS` の各項目のオフセット) と, Metal の引数の番号 (MSL の関数の宣言から読んだもの)
- 生成した GLSL の行数と, 本体が始まる行 (元の .fs と生成物の行の対応)

`dump` の `<what>`.

| what | 出すもの |
|---|---|
| `glsl-vert` / `glsl-frag` | 生成した GLSL (VDMX のエラー画面の GLSL と `diff` で比べる用) |
| `spirv-vert` / `spirv-frag` | SPIR-V の逆アセンブル (`spirv-cross` ではなく `glslang` の `-H` などで得る. 方法は実装時に決める) |
| `msl-vert` / `msl-frag` | spirv-cross が出した Metal のコード |
| `reflect-vert` / `reflect-frag` | spirv-cross の `--reflect` の JSON. オフセットの確認用. ここの `binding` は Metal の引数の番号ではない (4 章) |
| `uniforms` | 1 フレーム目に実際に詰める値を, 項目名, オフセット, 値の表で (値の詰め方のずれを探す用. `--set` も効く) |

- `dump` は `.fs` だけを入力にし, 途中の段で失敗したら, そこまでの生成物は出せる. 例えば glslang で落ちるシェーダーでも `glsl-frag` は出せる.
- 全部まとめてファイルに残したいときは, 共通オプションの `--keep-intermediates DIR` を使う.
- check でエラーが出たときは全文を出さず, エラーの行の前後数行を元の .fs の行番号付きで出す.

共通オプション.

| オプション | 既定 | 意味 |
|---|---|---|
| `--keep-intermediates DIR` | なし | 生成した GLSL, SPIR-V, MSL を保存する (デバッグ用) |

描画オプション (render と bench).

| オプション | 既定 | 意味 |
|---|---|---|
| `--size WxH` | `1920x1440` | 出力サイズ. 呼び出し元のプリセットに合わせた既定 |
| `--fps N` | `60` | 疑似時間の刻み. `TIME = i / N`, `TIMEDELTA = 1 / N`, `FRAMEINDEX = i` |
| `--set NAME=VALUE` | なし | 入力を固定値にする (複数可). `color` は `r,g,b,a`, `point2D` は `x,y` |
| `--feed-envelope` | off | パターンに合う入力に envelope を流し込む. render は envelope で描き, bench は 6 章の 3 つのモードを測る |
| `--feed-envelope-pattern REGEX` | `^(Level\|Lv)(?![a-z]\|Gain$)` | envelope を流し込む float 入力の名前. `--feed-envelope` が無いと使い方の誤り. info でも使え, 合う入力に `[envelope]` と付く |
| `--images DIR` | シェーダーの場所から解決 | IMPORTED の基準ディレクトリを上書き |

計測オプション (bench).

| オプション | 既定 | 意味 |
|---|---|---|
| `--warmup N` | `60` | 計測前に空回しするフレーム数 (持続バッファが溜まるまで) |
| `--frames N` | `240` | 計測するフレーム数 |
| `--repeat N` | `1` | 計測を何回繰り返して中央値を取るか |
| `--results FILE` | `.isftool/results.jsonl` | 結果を 1 行 1 計測で追記する |
| `--compare` | on | 同じシェーダー, 同じ条件の前回の結果との差 (%) を表に出す |
| `--json` | off | 表の代わりに JSON を標準出力に出す |

終了コード. 全部成功で 0, いずれかのシェーダーがコンパイルや描画に失敗したら 1, 使い方の誤りは 2.

## 6. 入力の与え方 (envelope)

GPU コストは入力の値で変わる. Level が 0 (無音または未割り当て) だと描画を省くシェーダーが多く, 実際より軽く出る. 本番でカクつくのは音が大きく描く要素が最も多い瞬間なので, 複数のモードで測る.

- 対象の入力とは `--feed-envelope-pattern` に合う名前の float 入力. 既定のパターンは呼び出し元の Level 入力の規約に合わせてあり, `LevelGain` は除外する.
- 名前 (2026-11-06, ユーザーの判断). 流し込む値は音を解析した帯域ごとの大きさなので envelope と呼ぶ. 音声データそのものと取り違えないよう audio は避け, VDMX の Filter という概念も CLI には出さない. `feed X to Y` の語順に合わせて `--feed-envelope` とし, 対象を選ぶ正規表現は `--feed-envelope-pattern` (既定値あり) にした. オンとオフを決めるのは `--feed-envelope` だけで, パターンだけを渡すと使い方の誤りにする.
- モード. `--feed-envelope` が無ければ `default` だけを測る. あれば bench は次の 3 つを測り, render は `envelope` で描く.
  - `default`: 全入力が DEFAULT. 対象の入力も DEFAULT (呼び出し元では 0).
  - `envelope`: 対象の入力を定義順に envelope の帯域 1, 2, ... に割り当て, 足りなければ `n % count + 1` で折り返す (呼び出し元が VDMX の Filter に割り当てる規則と同じ). 値は envelope を疑似時間で引いた値 × (MAX − MIN) + MIN. ほかの入力は DEFAULT.
  - `max`: 対象の入力を MAX にする. ほかは DEFAULT.
- envelope の中身. VDMX の Audio Analysis をマイクで 30 秒, OSC で記録した `/Filter 1` から `/Filter 16` の JSON Lines を `Scripts/gen_envelope_data.py` で `Sources/ISFKit/EnvelopeData.swift` に変換して組み込んだ. 時刻は 0.1 ms 単位, 値は Float32 で, 元の値をそのまま持つ. SwiftPM のリソースはバイナリの隣にバンドルが要り, 1 ファイルで配れなくなるので使わない. 帯域ごとに時刻以前の最後の値を使い (直前値保持), envelope の長さで繰り返す. 呼び出し元の preview と同じ引き方. ファイルを差し替えるオプションは今は無い.
- `event` 入力は常に false. `--set NAME=1` で毎フレーム true にできる.
- `--set` は全モードで最後に適用する.
- 実装して分かったこと (M4).
  - 帯域の数. 呼び出し元は VDMX のプロジェクトの Audio Analysis にある Filter の数で折り返すが, isftool にはプロジェクトが無いので, envelope の帯域の数 (16) を使う.
  - 入力の値が毎フレーム変わる envelope モード (当時の名前は recording) では, パスの大きさも毎フレーム評価し直す (CPU の時間で, GPU の時間には入らない).
  - Level で描く絵は変わっても, GPU の時間は 3 つのモードで同じシェーダーが多い (9 章の M4). 画素ごとの計算量が Level に依らない作りのため. Level で重さが変わるのは, Level に応じて描く要素の数を増やすシェーダー.
- `image`, `audio`, `audioFFT` 型の入力には, ISFMSLScene と同じく 0 で埋めた 64x64 の BGRA8 テクスチャを渡す (検証済み. ISFMSLScene は値の無い画像と音声の入力にこれを渡す). VDMX は実際の音声を渡すので, bench の表には注記する.

## 7. 処理の流れ

### 7.1 ISF の読み込み

- 読み込みは ISFGLSLGenerator の `VVISF::CreateISFDocRef(path, true)` に任せる (メタデータの JSON, INPUTS, PASSES, IMPORTED, 同名の `.vs`). 例外 (`VVISF::ISFErr`) は check の失敗 (`stage: parse`) として報告する.
- 入力の一覧, パス, 画像は `ISFDoc` の `inputs()`, `renderPasses()`, `imageImports()` から取る. Level 入力の判定など isftool 独自の処理はその上に載せる.
- `.vs` の扱いも ISFGLSLGenerator に任せる (`hasCustomVertShader()`).
- `WIDTH` / `HEIGHT` は ISF の式. ISFGLSLGenerator の `ISFPassTarget::evalTargetSize(width, height, symbols)` が exprtk で評価する (入力名を変数として渡す). 自前の評価器は書かない. 呼び出し元で実際に使われている形 (2026-11-04 に grep で確認).
  - 数値: `"1"`, `"4"`, `"48"`, `"512"`, `"1100"` など
  - 出力サイズ: `"$WIDTH"`, `"floor($WIDTH/2.0)"`
  - 入力値を含む: `"floor($WIDTH/$CellSize)"`, `"floor($HEIGHT/($CellSize*0.866))"`
  - 関数の入れ子: `"min($WIDTH, 640)"`, `"max(1, floor($HEIGHT * min(1, 640 / $WIDTH)))"`
- 入力値で大きさが変わるので, ISFMSLKit と同じく毎フレーム評価し, 大きさが変わったらテクスチャを作り直す. 持続バッファの初期内容は 7.3 を参照.
- 呼び出し元に `.vs` を持つシェーダーと `FLOAT: true` のパスは今のところ無い (2026-11-04 確認). `audio` 型の入力を持つのは 2 本. IMG 系の関数は `IMG_PIXEL` `IMG_NORM_PIXEL` `IMG_SIZE` `IMG_THIS_PIXEL` が使われ, `IMG_THIS_NORM_PIXEL` は使われていない.

### 7.2 check

1. ISFGLSLGenerator で ISF を読み, `generateShaderSource(&frag, &vert, VVISF::GLVersion_4, true)` で GLSL を作る. 例外は `stage: parse`.
2. glslang で頂点とフラグメントを別々に SPIR-V へ (引数は 2.5 と同じ). 失敗したら `stage: glsl` とエラーを報告する. エラーの行番号は生成した GLSL の行で, VDMX のエラー画面の番号 (`ERR: 111:` など) と同じ数え方. その番号と, 元の .fs の行の両方を出す. 前置きはメタデータのブロックと置き換わるので, 前置きの行数を引くだけでは合わない. 「元の .fs で本体が始まる行 − 生成した GLSL で本体が始まる行」を足す. IMG 系の書き換えは 1 行の中で収まるので, この差は 1 つの定数で済む見込み. ただし ISFGLSLGenerator は `IMG_THIS_PIXEL` 用の宣言なども足すので, 実装時に生成物を見て確かめる.
3. spirv-cross で MSL へ (引数は 2.5 と同じ. 関数名は `VV<ファイル名>VertFunc` / `VV<ファイル名>FragFunc`). 失敗したら `stage: spirv-cross`.
4. `makeLibrary(source:)` で Metal へ. 失敗したら `stage: metal`.
5. 解決できない uniform の検査 (`stage: unbound`). MSL の関数の引数のうち, ISF のホストが値を渡せないもの (シェーダー本体が自分で宣言した `uniform` など) があれば失敗にする. ISFMSLKit の `ISFMSLFindUnboundArgs` と同じ判定にする.
6. 各段の所要時間 (ms) も出す. VDMX でクリップを読み込むときの重さの目安になる.

### 7.3 描画 (Metal)

ISFMSLKit の `ISFMSLScene.mm` (2.5) に合わせる. 迷ったらそのソースを正とする.

- パスは `renderPasses()` の順. `TARGET` のあるパスはそのバッファへ, 最後のパス (TARGET なし) は出力テクスチャへ描く.
- 頂点データ: パスの描画サイズ W×H のピクセル座標の四角形 (z=0, w=1). 3.1 の射影で NDC に変換される. 頂点の並びと形 (三角形 2 枚か strip か) は ISFMSLKit の `resToQuadVertsDict` を作っている箇所に合わせる.
- 頂点データのバッファ番号は「頂点関数が使う最大のバッファ番号 + 1」. `MTLVertexDescriptor` もその番号で作る. uniform と同じ番号にするとエラーにならず位置がでたらめになる.
- uniform: ISFGLSLGenerator が返す大きさを 48 の倍数に切り上げたバイト列を作る. 先頭 48 バイトが `ISFShaderRenderInfo`, 画像ごとの `ISFShaderImgInfo` と入力の値は `offsetInBuffer()` の位置に書く. パスごとに `PASSINDEX` と `RENDERSIZE` を書き換え, 新しい `MTLBuffer` にコピーして頂点とフラグメントの両方に渡す. 1 つの `MTLBuffer` を使い回すと, GPU が実行する時点の値 (後のパスの `PASSINDEX` など) を読んでしまう. 4 KB 未満なら `setVertexBytes` / `setFragmentBytes` でもよい.
- `ISFShaderImgInfo`: `rect` はテクスチャの中の使う範囲 (普通は 0,0,1,1), `size` はそのピクセル数, `flip` は普通のテクスチャで 1 (2.5).
- パスのテクスチャ: 8 bit は `bgra8Unorm`, `FLOAT` は `rgba32Float` (検証済み. `VVMTLPool rgbaFloatTexSized` の形式). 最後のパスが `FLOAT` のとき, ISFMSLScene は 8 bit の出力テクスチャ (RENDERSIZE の大きさ) に直接描かず, VVMetalKit の `CopierMTLScene` で写す. ISFMSLScene は `SizingModeFit` を渡すが, `CopierMTLScene` はこの値を使わず, 元の画像全体を出力全体に引き伸ばす (compute シェーダーで, 線形補間, 端はクランプ, 書き込むときに 0 から 1 に収まる). isftool はこの compute シェーダーを移して同じように写す (ソースで確かめた. GPU 時間にこの写しも入る).
  - 検査用シェーダー (`float_accumulate.fs`, `byte_accumulate.fs`, `float_output.fs`) で確かめた. 毎フレーム 0.001 を足すと, FLOAT のバッファは 100 フレームで 0.1 (8 bit で 26) になり, 8 bit のバッファは 0 のまま. 半分の幅の FLOAT の最後のパスは, 出力の大きさに引き伸ばされる. VDMX (120 fps) でも同じだった (検証済み). FLOAT のバッファは 600 フレームごとに 0 から 6 割くらいの灰色まで明るくなり, 8 bit のバッファは黒のまま, 半分の幅の FLOAT の最後のパスは赤が出力のちょうど左半分を占め, 帯は出なかった (fit ではなく引き伸ばし). 検査用シェーダーは VDMX で見られるよう 600 フレームごとにやり直す. 呼び出し元には 8 bit 前提の値の詰め方をしているシェーダーがある.
- 持続バッファの初期内容 (未検証). ISFGLSLGenerator の `ISFPassTarget.hpp` のコメントには「作ったときに黒で埋める必要がある」とあるが, ISFMSLKit はテクスチャを VVMetalKit の `VVMTLPool` から取り, ロードアクションも `dontCare` で, VVMetalKit のソースにテクスチャを消す処理は見当たらなかった. つまり VDMX でも 1 フレーム目の持続バッファの中身は不定かもしれない. isftool は結果を毎回同じにするため黒 (0,0,0,0) で埋める. 大きさが変わったバッファも作り直して黒から始める (ISFMSLScene も大きさが合わなければ新しいテクスチャを取る). 計測には影響しないが, render の PNG を VDMX と比べるとき (M3) は最初の数フレームが違いうることに注意する.
- 読み書きの入れ替え (検証済み). ISFMSLScene はパスごとに新しいテクスチャに描き, 描き終えたらそれをパスの画像にする. 描いている間に読めるのは前の画像なので, 持続バッファは自分の前のフレームを読める. isftool はパスごとに 2 枚を持って入れ替える. TARGET のあるパスは, 描かれる前でも前のフレームの画像が見える.
- 持続でないパスの扱い. ISFMSLScene はフレームの終わりに画像を手放し, 次のフレームでプールから取り直す (中身は不定). isftool は前のフレームの画像を持ち越す. 描く前に読むシェーダーでなければ結果は変わらない.
- パスの大きさは入力の値が変わったときだけ評価し直す (exprtk は入力の値を変数として使うので).
- ロードアクションはカスタムの頂点シェーダーがあるときだけクリア, それ以外は `dontCare` (ISFMSLKit と同じ). 持続でないバッファの初期内容は保証されないので, それに頼るシェーダーは VDMX でも不定になる.
- サンプラー: 正規化座標, 線形補間, 端はクランプ.
- IMPORTED の画像は ISFMSLScene と同じく `MTKTextureLoader` で, `SRGB: false` を付けて読む (検証済み). 読み込んだテクスチャは 1 行目が画像の上になる.
- 上下の向き (M2 と M3 で必ず確かめる).
  - 形の向き: 3.1 の射影では `VERTEXDATA (0,0)` が NDC の y = +1 (上) に来るので, 正規化座標の y = 1 が出力 PNG の一番上の行になる見込み. M2 で preview と上下反転して出たら, 頂点の並べ方が間違っている. テクスチャの反転で補わないこと.
  - テクスチャの向き (検証済み, M3). ISFMSLScene が使うテクスチャ (プールのものも `MTKTextureLoader` のものも) は `flipV` が NO なので, `_X_flip` は常に 1 になる. 生成 GLSL は flip が 1 のとき y を 1 − y にして読むので, 左下原点の ISF の座標で, 1 行目が上のテクスチャを正しく読める. 次の 2 本で確かめ, 統合テストに残した.
  - バッファ: 1 フレーム目に上半分だけ白を書き, 2 フレーム目以降は自分のバッファを読んで写すシェーダー (`Tests/ISFKitTests/Fixtures/persistent_orientation.fs`. 左半分は `IMG_THIS_PIXEL`, 右半分は `IMG_NORM_PIXEL`). 10 フレーム後も上半分が白だった.
  - 画像: 上半分が白の PNG を IMPORTED で読んで表示するシェーダー (`imported_orientation.fs` と `top_white.png`. 左半分は `IMG_NORM_PIXEL`, 右半分は `IMG_PIXEL`). 上半分が白だった.
- 実装して分かったこと (検証済み, M2).
  - 向き. 3.1 の射影と ISFMSLScene の頂点の並び `(0,0) (0,H) (W,0) (W,H)` をそのまま使うと, 正規化座標の y = 1 が PNG の一番上の行, x = 1 が一番右の列になった. どこにも反転は要らない. `Tests/ISFKitTests/Fixtures/orientation.fs` と統合テスト `testRenderFacesTheSameWayAsISF` に残した.
  - 頂点の記述子. ISFMSLKit は `layouts[1]` に stride を書くが, 頂点データの番号は「頂点関数の最大のバッファ番号 + 1」なので, 番号が 1 でないシェーダーでは合わない. isftool は同じ番号の `layouts` に書く. 呼び出し元の全シェーダーで番号は 1 なので結果は変わらない.
  - `DATE` は ISFMSLScene と同じくフレームごとに手元の時計から入れる. 呼び出し元で `DATE` を使うシェーダーは無いので, PNG の再現性には影響しない.
  - 入力の値は ISFGLSLGenerator の `currentVal()` (読み込んだ直後は DEFAULT) から始め, `event` は false, 最後に `--set` を当てる (6 章).
- 出力は `--size` のテクスチャ. render は PNG に書き出す (straight alpha. ISF の出力は RGB が 0 のところ alpha 0 という前提).

### 7.4 計測

- 1 フレーム = 1 つの `MTLCommandBuffer`. 全パスを積んで `commit` し `waitUntilCompleted`. GPU 時間は `gpuEndTime − gpuStartTime`. CPU 側で uniform を詰める時間は含めない.
- `--warmup` フレーム描いてから `--frames` フレーム測る. 疑似時間は空回しから通しで進める.
- 集計: 中央値, p95, 最小, 平均, 標準偏差 (ms). 表示は中央値と p95. `--repeat` が 2 以上なら各回の中央値の中央値と, 回ごとのばらつき.
- 120 fps 相当の 8.3 ms と 60 fps 相当の 16.7 ms を目安として表に印を付ける. ただし VDMX の実測とは一致しない. 順位付けと前後比較のための数字であることを README にも書く.
- 計測の下限の確認: 何もしないシェーダー (`gl_FragColor = vec4(0.0);`) が 1 ms を大きく下回らなければ, 計測に余計なものが入っている. Apple GPU では 1920x1440 の 1 パスにも書き出しのコストがあるので 0 にはならない.
- フレームごとに `waitUntilCompleted` で待つので, フレームの間は GPU が休む. 連続で描き続けるときより数字が少し高めに出るが, 順位付けと前後比較には問題ない. README にも書く.
- `compile_ms.metal` は 2 回目以降に速く出る. OS が Metal のコンパイル結果をキャッシュするため. 初回の値とキャッシュ後の値を混同しない.
- 1 本ずつ測る. 測る順番の影響を減らすため, シェーダーを切り替えたら最初の数フレームを捨てる (warmup に含まれる).
- 実装して分かったこと (検証済み, M4).
  - GPU のクロック. check で glslang と SPIRV-Cross を動かす数百 ms の間に GPU のクロックが下がり, 軽いシェーダーでは warmup の 60 フレームでは戻らない. あるシェーダーは 1 回目の計測だけが 0.30 ms で, 2 回目以降は 0.17 ms だった. そこで計測の前に, 捨てる renderer で 0.5 秒描き続けて GPU を起こす. 何もしないシェーダーも 0.16 ms から 0.036 ms になった.
  - `--repeat`. 回ごとに renderer を作り直し, フレーム 0 から同じフレームを測る. 時刻を続けて測ると, 時間で描く量が変わるシェーダー (line_space は線が増える) の回ごとの差が中身の差になってしまうため. 表には回ごとの中央値の幅 (最大 − 最小) を中央値で割った値を `spread` として出す.
  - 集計. 中央値は個数が偶数なら真ん中の 2 つの平均. p95 は nearest rank (`ceil(0.95 n)` 番目) で, 必ず測った値のどれかになる. 標準偏差は母標準偏差 (測ったフレームが全体で, 標本ではないため).
  - `compile_ms.metal` は最初の renderer を作る時間 (MSL のコンパイルとパイプラインの作成).

### 7.5 出力

- 標準出力の表 (bench). 列: shader, mode, median ms, p95 ms, passes, 前回比 %, 注記 (audio 入力, 失敗理由など). 既定は median の降順.
- 結果ファイル `.isftool/results.jsonl` に 1 計測 1 行で追記する.

```json
{"at":"2026-11-04T05:00:00Z","shader":"shaders/line_space.fs","sha256":"<.fs の内容のハッシュ>",
 "git":{"commit":"1a2b3c4","dirty":true},"size":[1920,1440],"fps":60,"mode":"max",
 "warmup":60,"frames":240,"repeat":1,
 "ms":{"median":3.21,"p95":3.40,"min":3.10,"mean":3.22,"stddev":0.05},
 "compile_ms":{"glsl":12.0,"spirv_cross":8.0,"metal":40.0},
 "device":"Apple M4 Pro","isftool":"0.1.0"}
```

- 前回比は, 同じ shader パス, size, mode, frames の直近の行と比べる. `sha256` が違えばシェーダーが変わったことが分かる.
- `shader` はコマンドラインで渡したパスをそのまま入れる (同じ場所から同じパスで渡せば前回と比べられる. 別のディレクトリから相対パスで渡すと別のシェーダーとみなされる).
- 実装で足した項目. `passes` (パスの数) と, `--repeat` が 2 以上のとき `repeats` (回ごとの中央値). そのとき `ms.median` は回ごとの中央値の中央値.
- 結果は 1 本 1 モード測るたびに追記する (長い一括計測が途中で止まっても, それまでの結果が残る). 失敗したシェーダーは結果ファイルに書かず, 表と `--json` の `failures` にだけ出す.
- `git` はシェーダーのあるリポジトリで `git rev-parse` と `git status --porcelain` を取る. リポジトリでなければ省く.

## 8. 構成 (SwiftPM)

```
isftool/
├─ Package.swift                 # swift-tools-version 6.0, macOS 14 以上, 依存は swift-argument-parser だけ
├─ Vendor/
│  └─ ISFGLSLGenerator/          # git submodule. github.com/mrRay/ISFGLSLGenerator を 2b5507b に固定 (BSD 3-Clause)
├─ Sources/
│  ├─ isftool/                  # 実行ファイル. 引数の解釈と表の出力だけ
│  ├─ CISFGLSLGenerator/         # C++ ターゲット. Vendor の libISFGLSLGenerator/src と include をビルドする
│  ├─ ISFGLSLBridge/             # C++ ターゲット. 下の C 関数を extern "C" で公開する薄い層
│  └─ ISFKit/                    # Swift ライブラリ. 他から再利用できるように分ける
│     ├─ ISFDocument.swift       # ISFGLSLBridge を包む. 入力, パス, 画像, 生成した GLSL, オフセット
│     ├─ Toolchain.swift         # 組み込んだ glslang / SPIRV-Cross の呼び出し (2.6)
│     ├─ MSLSignature.swift      # MSL の関数の宣言から引数の番号を読む (ISFMSLParseFuncSignature 相当) と unbound の検査
│     ├─ UniformBuffer.swift     # オフセットに従って値を詰める
│     ├─ MetalRenderer.swift     # パイプライン, パス, 持続バッファ, 画像, 出力
│     ├─ InputDriver.swift       # 6 章のモード, 録音の読み込み, --set
│     ├─ Bench.swift             # 計測と集計
│     └─ Results.swift           # results.jsonl の読み書きと前回比
├─ Tests/ISFKitTests/            # 9 章の検査をテストにする
│  └─ Fixtures/                  # 検査用の小さな .fs と PNG
├─ README.md
└─ design.md                     # この文書
```

- ビルドは `swift build -c release`. 実行ファイルは `.build/release/isftool`.
- ISFGLSLGenerator は C++ (C++17 以上, exprtk と nlohmann json をヘッダーで含む). Swift から直接 C++ を呼ぶ (C++ 相互運用) より, `ISFGLSLBridge` で必要な操作だけを C の関数にして呼ぶほうが壊れにくい. 例: 文書を開く / 閉じる, GLSL を作る (頂点とフラグメントの文字列, UBO の大きさ), 入力とパスと画像の一覧と各オフセット, パスの大きさの評価, エラー文字列. exprtk はコンパイルが重いので, リリースビルドの時間に注意する.
- ISFGLSLGenerator のビルドに使うコンパイルフラグは, ISFMSLKit の `ISFGLSLGenerator_build_script.sh` と ISFGLSLGenerator の `CMakeLists.txt` を参考にする. 実際に要ったのは C++20 (`cxx_std_20`) と `MAC=1` の定義 (トップの `CMakeLists.txt` が定義する. 無いと `GetHomeDirectory` がコンパイルできない). リリースビルドは全体で約 30 秒 (検証済み).
- `ISFGLSLBridge` は ISFDoc の中身を JSON (同梱の nlohmann json) で 1 回に渡す. Swift 側はそれを `ISFDocumentInfo` に読み, 以降の処理は全てこの値を受け取る. テストでは C++ を通さずに値を手で作れる.
- SwiftPM のターゲットは submodule をそのまま指せる. 例:

```swift
.target(
    name: "CISFGLSLGenerator",
    path: "Vendor/ISFGLSLGenerator/libISFGLSLGenerator",
    sources: ["src"],
    publicHeadersPath: "include",
    cxxSettings: [.headerSearchPath("include")]
),
// Package 全体に cxxLanguageStandard: .cxx17 を付ける
```

- BSD 3-Clause は著作権表示の同梱を求めるので, submodule の `LICENSE.txt` を消さない. 配布物を作るときは README からも辿れるようにする.
- `swift-tools-version 6.0` だと Swift 6 の厳密な並行性検査が有効になり, Metal のオブジェクトが `Sendable` でないことで大量の診断が出る. 各ターゲットに `swiftLanguageModes: [.v5]` を付ける.
- swift-argument-parser を使う (サブコマンドとヘルプの手間を省くため). 取得にネットワークが要る.
- 外部コマンドの呼び出しは `Process`. 中間ファイルは一時ディレクトリに置き, `--keep-intermediates` のときだけ残す.
- シェーダーごとの変換結果 (MSL) は `.fs` の内容のハッシュで `~/Library/Caches/isftool/` に保存し, 同じ内容なら再変換しない (チューニングで何度も測るため).

## 9. マイルストーンと完了条件

各段階は前の段階が完了条件を満たしてから進める.

### M0: 骨組み
- Package.swift, `isftool --version`, `isftool check --help` が動く.
- ISFGLSLGenerator を submodule で入れ, `CISFGLSLGenerator` と `ISFGLSLBridge` がビルドできる.

### M1: check
- ISFGLSLGenerator で GLSL を作り, 4 章の経路で Metal までコンパイルする. 7.2 の unbound 検査も入れる (字句検査も入れたが, 2.6 で外した).
- 完了条件.
  0. line_space の修正前の版 (下の 2.) で `dump glsl-frag` した出力が, 3 章の写し (VDMX のエラー画面) と空白を除いて一致する. ISFGLSLGenerator の組み込みが VDMX と同じものを出す証拠になる.
  1. line_space (現在の版, `Tests/ISFKitTests/Fixtures/line_space.fs`) が全段成功.
  2. line_space の修正前の版 (`line_space_layout.fs`) が `stage: glsl` で失敗し, メッセージに `unexpected LAYOUT` を含む.
  3. thin_barcode の修正前の版 (`thin_barcode_layout.fs`) が同じく失敗する. 入力名が原因の例.
  4. super_polygons の修正前の版 (`super_polygons_vertex.fs`. 関数 `vec2 vertex(float column, float row)` を持つ) が `stage: lint` で失敗する. あわせて, 字句検査を外したときに spirv-cross と Metal の段で通るか落ちるかを記録し, 2.5 の未解明の点に結果を書き足す.
  5. 呼び出し元のシェーダー全部を check して, 失敗の一覧を出す. VDMX で普通に読み込めているシェーダーが失敗したら, isftool 側の呼び出し方 (引数, 組み込み方) をまず疑う.
  6. エラーの行番号が元の .fs の行と一致する.
  7. `--reflect` で得た `VVISF_UNIFORMS` のオフセットが, ISFGLSLGenerator の `offsetInBuffer()` と一致する (数本で確かめてテストに残す).

- `info` と `dump` も M1 で作る (check の生成物をそのまま出すだけなので). 完了条件: `dump glsl-frag` の出力が 3 章の形と一致する.
- 結果 (2026-11-04).
  - 0: 3 章の写し (`Tests/ISFKitTests/Fixtures/vdmx_line_space.*.glsl`) と, コメントと空白を除いて一致した. 生成物には 3.1 に無いコメント行 (`//mat4 projectionMatrix ...`) があるが, エラー画面の写しを整えたときに落ちたものとみなした.
  - 1 から 4, 6, 7: 統合テストで確かめた. 2 は生成 GLSL の 111 行目, 元の .fs の 90 行目. 3 は入力名がブロックのメンバーになるので頂点シェーダーで先に落ちる (生成 GLSL の 21 行目. 元の .fs の行は無い).
  - 5: 162 本のうち 159 本が成功, 3 本が失敗.
    - 1 本は `stage: metal`. 関数名 `level` が Metal の `metal::level` とぶつかる (`reference to 'level' is ambiguous`). Homebrew の SPIRV-Cross は `level` を改名しない. VDMX でも同じエラー (同じ行番号) で読み込めなかった. VDMX が出した MSL は isftool の `dump msl-frag` と行番号まで一致した.
    - 2 本は `stage: lint`. 変数名 `visible`. SPIRV-Cross は改名せず, Metal もコンパイルできた. VDMX でもエラーにならなかったので, `visible` を字句検査の一覧から外した. 外した後は 162 本のうち 161 本が成功する.

### M2: 1 パスの描画
- 1 パスのシェーダーを `render` で PNG にする.
- 完了条件: パスの無いシェーダーを 1 枚出し, preview で同じ時刻を見たものと形が同じ (上下左右の向きを含む). 半画素の差は許す.
- 結果 (2026-11-04).
  - preview には時刻を止めたり指定したりする方法が無いので, 時刻を速さの入力との積でしか使わないシェーダーを選び, その入力を 0 にして時刻に依らない絵で比べた. 形の位置と巻く向きが一致し, 上下左右とも反転していない (検証済み). 比べたのは目で見た形で, 画素ごとの差は取っていない.
  - 162 本を `--at 5` で描くと, 139 本が PNG になった. 残りは TARGET のあるパスを持つものと, 画像か音声の入力を持つもの (どちらも M3 まで描かずに理由を出して終わる), それと Metal で落ちる 1 本.
  - 描けたもののうち 23 本は全面が透明だった. Level 入力が DEFAULT の 0 だと何も描かないシェーダーで, Level を 1 にすると描けた. 6 章の `max` モードが要る理由そのもの.

### M3: 複数パス, 持続バッファ, 画像
- 7.3 の向きの検査用シェーダー 2 本で `_X_flip` の扱いを決め, テストに残す.
- 完了条件: 幅 4 の持続バッファ (line_space), 幅 48 の持続バッファと IMPORTED 画像, 出力と同じ大きさの持続バッファを持つシェーダーが, 数十フレーム進めた PNG で preview と同じように見える.
- 結果 (2026-11-04).
  - `render` に `--frames N` を足した. `--at` の時刻から N 枚を書き出し, それより前のフレームも 0 から描く (持続バッファを溜めるため). 1 枚で `--out` が `.png` ならそのファイルに, それ以外は `--out` をディレクトリとして `<名前>_<FRAMEINDEX 5 桁>.png` に書く.
  - 3 本とも `--at 3 --size 1280x720` (180 フレーム) で描き, preview の画面と見比べて同じ形になった. IMPORTED 画像は上下反転していない. 比べたのは目で見た形で, 時刻と Level の値は preview と揃えられないので, 画素ごとの差は取っていない.
  - 162 本を `--at 1` で描くと, 161 本が PNG になった (残りは Metal で落ちる 1 本). 全面が透明なのは 24 本で, どれも Level 入力が DEFAULT の 0 のとき何も描かない.

### M4: bench
- 7.4 と 7.5 と 6 章を実装する.
- 完了条件.
  1. 何もしないシェーダーが 1 ms を大きく下回る.
  2. 同じシェーダーを 3 回測って中央値のばらつきが 5% 以内.
  3. preview で重いと分かっているものが上位に来る.
  4. Level で描く要素の数が変わるシェーダーは, 当時の `recording` と `max` のモードのほうが重く出る. 描く絵は変わっても GPU の時間が変わらないシェーダーは例から外した (2026-11-04, ユーザーの判断).
- 結果 (2026-11-04, 1920x1440 は既定の大きさ).
  1. 何もしないシェーダー (`Tests/ISFKitTests/Fixtures/empty.fs`) は 1920x1440 で 0.036 ms.
  2. `--repeat 3` で, 軽いシェーダーは 3 回とも同じ値か幅 4.4%, 77 ms ほどの重いシェーダーは幅 0.3%. 計測の前に GPU を起こすようにする前は, 軽いシェーダーの 1 回目だけが倍近く遅かった (7.4).
  3. preview で重い 3 本が 1280x720 の max モードで 10 ms から 29 ms と上位に来て, 軽いものは 0.3 ms 前後だった. 3 本の中の順番は preview と違う. preview は WebGL で, Level も録音から与えている.
  4. 画素ごとの計算量が Level に依らないシェーダーは 3 つのモードで同じ時間だった (Level の値は描画に届いていて, PNG は違う). Level に応じて描く要素を増やすシェーダーは default 0.51 ms, recording 12.5 ms, max 32.4 ms で, モードの違いを捉えられた.

### M5: 仕上げ
- README (インストール, 例, 数字の読み方と限界).
- 呼び出し元の, 実際に使うシェーダーを全部測る例. 一覧を作る規則は呼び出し元のものなので, isftool 本体はこの規則を知らなくてよい.
- 結果 (2026-11-04). スクリプトは呼び出し元のリポジトリに置き (ユーザーの判断), isftool の README からは外した. スクリプトはリポジトリの直下から 1 本ずつ `isftool bench` を呼ぶ. 直下から呼ぶのは, パスを毎回同じにして前回と比べられるようにするため. 61 本を 1280x720, `--warmup 10 --frames 30` で 3 モード測って約 2.5 分, 全部成功した. 最も重いものは max で 42.84 ms だった.

## 10. 未決事項とリスク

- **glslang と SPIRV-Cross の版の違い** (解決済み, 2026-11-05). VDMX は VIDVOX の fork の古い版を使う (検証済み. VDMX6 Plus 6.1.3.6 の `ISFMSLKit.framework/Versions/A/Frameworks/` にある `libGLSLangValidatorLib.dylib` と `libSPIRVCrossLib.dylib` は, ISFMSLKit の `extern/` にあるものと arm64 の `__TEXT,__text` が一致した. ファイル全体が違うのはコード署名の差. upstream の glslang や SPIRV-Cross を直に使ってはいない). fork は CLI をライブラリとして呼べるようにし, CLI の `main()` に引数を渡す関数を足しただけの薄いもの (ISFMSLKit の README). upstream と diff すると, 変換の処理には手が入っていなかった (2.6). ISFMSLKit の `extern/` にある SPIRV-Cross の dylib は `sdk-1.3.239.0-406-gfbff56a2` (2025-03-19 にビルド) で, Homebrew の 1.4.363.0 より古い. glslang の dylib は文字列から版が読み取れなかった. VDMX と同じ版を組み込むことにした (ユーザーの判断. 2.6). VDMX が glslang や SPIRV-Cross を差し替えたら, 2.6 の比べ方をやり直す.
- VDMX6 が使っているのが公開版の ISFMSLKit そのものかは分からない (社内で手を入れている可能性がある). VDMX で落ちて isftool で通るシェーダーが見つかったら, エラー画面の GLSL を 3 章に追記し, check のテストに足す.
- `audio` / `audioFFT` 入力に VDMX が渡すテクスチャの形 (幅, 高さ, 形式) は分かっていない. ISFMSLKit は値が無いとき 64x64 の空のテクスチャを渡すだけで, 音声を詰める処理は VDMX 側にある. GPU 時間への影響は小さいとみて, 空のテクスチャで測る.
- GPU 時間は VDMX の出力 fps と一致しない (VDMX は合成, レイヤー FX, Syphon 出力も描く). 順位付けと前後比較に使う.
- Apple GPU はタイルベースなので, パスの多いシェーダーはパスごとのロードとストアのコストも乗る. これは VDMX でも同じなので, そのまま測る.
- 熱で GPU のクロックが下がると数字がぶれる. 長い一括計測では `--repeat` と並び順の工夫で見分ける.

## 11. 背景の資料

### VIDVOX の実装 (ghq で clone 済み)

- `~/src/github.com/mrRay/ISFGLSLGenerator/libISFGLSLGenerator/src/ISFDoc.cpp`: `generateShaderSource`, `_assembleShaderSource_VarDeclarations` (GLSL の組み立てと uniform の並び).
- `~/src/github.com/mrRay/ISFGLSLGenerator/libISFGLSLGenerator/include/VVISF_Base.hpp`: `ISFShaderRenderInfo`, `ISFShaderImgInfo`.
- `~/src/github.com/mrRay/ISFMSLKit/ISFMSLKit/ISFMSLCacheObject.mm`: GLSL → SPIR-V → MSL の流れと引数の番号の読み取り.
- `~/src/github.com/mrRay/ISFMSLKit/ISFMSLKit/ISFMSLScene.mm`: 描画 (テクスチャ, サンプラー, uniform, 頂点データ, flip).
- `~/src/github.com/mrRay/ISFMSLKit/ISFMSLKit/ISFMSLFuncSignature.mm`: 関数名の付け方, MSL の宣言の解析, unbound の検査.
- `~/src/github.com/mrRay/ISFMSLKit/ISFMSLKit/ISFMSLTranspilerError.mm`: VDMX と同じエラー文言.
