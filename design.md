# isfbench 設計書

ISF (Interactive Shader Format) シェーダーを VDMX6 Plus と同じ経路 (GLSL 4.00 → SPIR-V → Metal) で検査し, 描画し, GPU 時間を測る macOS 用の CLI.
この文書だけを読んで別セッションが実装を始められることを目指す. 既に手元で確かめたことは「検証済み」, 確かめていない推測は「未検証」と書き分ける.

## 0. 現状 (2026-11-04)

- 実装はまだ何も無い. M0 から始める.
- このマシンには Homebrew で glslang と spirv-cross を入れた (2.).
- 4 章の変換経路は一時ディレクトリで試しただけで, ファイルは残していない.
- VDMX が使っているとみられる VIDVOX の公開実装を見つけ, ソースを読んだ (2.5). GLSL の組み立ては自前で書かず, その実装 (ISFGLSLGenerator) を組み込む方針に変えた. 3 章の写しは, その実装と VDMX が一致することの証拠として残している.
- 決めたことと分かったことは全てこの文書にある. 実装中に新しく分かったことは, この文書の該当箇所を「検証済み」に書き換えていく.

## 1. 目的と動機

- 呼び出し元のリポジトリ `~/src/github.com/101000lab/vjcomponents` (以下 vjcomponents) は VDMX6 Plus 用の ISF シェーダー集. シェーダーの確認には WebGL のブラウザ preview を使っているが, VDMX とは別の経路なので次の 2 つが見えない.
  1. VDMX でだけ失敗するコンパイルエラー. 2026-11 に `layout` を変数名や入力名にしたシェーダー 2 本 (line_space, thin_barcode) が preview では通り, VDMX で `syntax error, unexpected LAYOUT` で失敗した. 以前には関数名 `vertex` が VDMX の Metal 変換で `expected unqualified-id` になった (vjcomponents の AGENTS.md に記録).
  2. シェーダーごとの GPU コスト. ライブで 16 レイヤー全てに ISF クリップを読み込むと出力が 9 fps 前後まで落ち, 見えている 1 枚 (line_space) だけにすると 120 fps だった. VDMX はクリップが入ったレイヤーを透明度 0 でも毎フレーム描く. どのシェーダーが重いかを VDMX を使わずに順位付けしたい.
- 最終形は単独の CLI `isfbench`. vjcomponents 固有の決まり (Level 入力の命名, 録音ファイルの形式) はフラグで差し替えられる既定値として持ち, リポジトリから切り離しても使えるようにする.
- 想定する使い方は 2 つ.
  - 全シェーダーをまとめて検査, 計測して重い順に並べる.
  - 1 本のシェーダーを何度も計測しながらチューニングする (前回との差を見る).

## 2. 環境 (検証済み, 2026-11-04)

| 項目 | 値 |
|---|---|
| マシン | Apple M4 Pro, Metal 3 |
| OS | macOS 15 (Darwin 24.6, arm64) |
| Swift | 6.1.2. Xcode は無く Command Line Tools のみ (`/Library/Developer/CommandLineTools`) |
| glslang | 16.6.0 (`/opt/homebrew/bin/glslang`, 別名 `glslangValidator`) |
| spirv-cross | 1.4.363.0 (`/opt/homebrew/bin/spirv-cross`) |

- Metal の実行時コンパイル `MTLDevice.makeLibrary(source:options:)` は Command Line Tools だけで動く (検証済み. swiftc で作った小さな実行ファイルで MSL をコンパイルできた).
- glslang と spirv-cross は外部コマンドとして呼ぶ. ライブラリとしてリンクはしない (SwiftPM でビルドを単純に保つため). パスは `--glslang` `--spirv-cross` で上書きでき, 既定は `PATH` から探す.

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

- **GLSL の組み立て**: `ISFDoc::generateShaderSource(&frag, &vert, VVISF::GLVersion_4, true)`. 最後の `true` は「入力を UBO (`VVISF_UNIFORMS`) にまとめる」. IMG 系の関数の書き換え, `IMG_THIS_PIXEL` 用に頂点シェーダーで座標を計算して渡す処理, `.vs` の扱い, uniform の並びとオフセットの計算は全てこの関数の中にある. よって isfbench はこのソースを組み込んで呼ぶ (8 章).
- **glslang に渡す引数** (`GLSLangValidatorLib.cpp`): `-G --amb --aml --stdin -S frag` (頂点は `-S vert`). `--amb` は `--auto-map-bindings`, `--aml` は `--auto-map-locations`.
- **SPIRV-Cross に渡す引数** (`SPIRVCrossLib.cpp`): `--rename-entry-point main <新しい名前> frag --msl -` (頂点は `vert`). MSL のバージョン指定も `--msl-decoration-binding` も無い. Metal の引数の番号は SPIRV-Cross が自動で振る.
- **関数名**: `VV<ファイル名>VertFunc` と `VV<ファイル名>FragFunc`. ファイル名 (拡張子なし) の英数字以外は `_` に置き換える (`ISFMSLFuncSignature.mm` の `ISFMSLEntryPointNamesForPath`).
- **解決できない uniform の検査**: シェーダー本体が自分で `uniform` を宣言すると, ホストが値を渡せない引数が MSL に残る. ISFMSLKit はこれを失敗として扱う (`ISFMSLFindUnboundArgs`). isfbench の check でも同じ検査をする.
- **uniform の詰め方**: 先頭に `ISFShaderRenderInfo` (48 バイト. `PASSINDEX TIME RENDERSIZE[2] DATE[4] TIMEDELTA FRAMEINDEX PADDING_INFO[2]`), 画像ごとに `ISFShaderImgInfo` (32 バイト. `rect[4] size[2] flip PADDING_IMG`), 入力の値が続く. 各入力と各バッファのオフセットは `generateShaderSource` が `offsetInBuffer()` に書き込み, 全体の大きさを返す (`VVISF_Base.hpp`, `ISFAttr.hpp`, `ISFPassTarget.hpp`). ISFMSLKit はこの大きさを 48 の倍数に切り上げたバッファをパスごとに `newBufferWithBytes` で作り, 頂点とフラグメントの両方に渡す.
- **`_X_flip`**: 普通のテクスチャで 1. コメントは「GLSL は左下原点で読むが Metal は左上原点なので, ここで反転する」(`ISFMSLScene.mm`). `rect` はテクスチャの中の使う範囲を正規化した値, `size` はその範囲のピクセル数.
- **パスのテクスチャ**: 8 bit は `BGRA8`, `FLOAT` は RGBA の float (`VVMTLPool` の `bgra8TexSized` と `rgbaFloatTexSized`). パスの大きさが変わったら作り直す.
- **ロードアクション**: カスタムの頂点シェーダーがあるときだけクリア, それ以外は `DontCare`. つまり持続でないバッファの初期内容は保証されない.
- **サンプラー**: 正規化座標, 線形補間, 端はクランプ.
- **頂点データ**: 解像度ごとに作った四角形のバッファを, 頂点関数が使う最大のバッファ番号 + 1 の番号に置く.

手元の Homebrew 版で, 上の glslang と SPIRV-Cross の引数をそのまま使って line_space を変換し, Metal でコンパイルできた (検証済み). 関数名 `vertex` を持つ自作の小さなシェーダーは, それでも Homebrew の SPIRV-Cross が `vertex0` に改名して通った. 一方 VDMX では `vec2 vertex(float column, float row)` を持つ super_polygons が `expected unqualified-id` で落ちた (vjcomponents の `5d195dd` で修正). 理由は分かっていない. VIDVOX の SPIRV-Cross の版の違いかもしれないが, SPIRV-Cross は以前から MSL の予約語を改名しているので, 版の違いだけとは言い切れない. 本物の super_polygons (修正前) を M1 で isfbench に通して確かめる. どちらの結果でも, Metal の予約語は isfbench が自前で検査する (7.2).

ISFMSLKit の `extern/` には, VIDVOX がビルドした glslang と SPIRV-Cross の dylib (arm64 と x86_64, macOS 15 以上) が同梱されている. これを呼べば VDMX と同じ版で変換できるが, このセッションでは外部のビルド済みバイナリの実行が権限確認で止められたので試していない. 使うかどうかはユーザーの判断待ち (10 章).

## 3. VDMX が組み立てる GLSL (検証済みの写し)

VDMX のエラー画面に出た, line_space.fs と thin_barcode.fs から VDMX が生成した GLSL をそのまま写す. isfbench は 2.5 の ISFGLSLGenerator を組み込むので, この形を自分で組み立てる必要は無い. この章は, 組み込んだ生成器の出力が VDMX と一致するかを確かめるための見本として使う (M1 の完了条件). 空白はエラー画面の表示で崩れているので整えた.

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

- 書き換えは ISFGLSLGenerator がするので, isfbench は自前で書き換えない.
- `gl_FragCoord` は `isf_FragCoord` に置き換わるが, 値は `gl_FragCoord` と同じ画素の中心 (x + 0.5, y + 0.5) になる. `isf_FragCoord` は頂点シェーダーの出力で, 頂点 (四隅) では `isf_FragNormCoord * RENDERSIZE` がちょうど 0 か W / H なので `floor` は何もしない. その値が面の中で線形に補間され, 画素の中心で評価される. 半画素のずれは無いので, 描画側で補正しないこと.

### 3.4 uniform ブロックの並び (検証済み)

1. 固定の 7 個: `int PASSINDEX; float TIME; vec2 RENDERSIZE; vec4 DATE; float TIMEDELTA; int FRAMEINDEX; vec2 PADDING_INFO;`
2. 画像ごと: `vec4 _X_imgRect; vec2 _X_imgSize; bool _X_flip; int _X_padding;`
3. INPUTS を定義順に. 型の対応は `float`→`float`, `long`→`int`, `bool`→`bool`, `event`→`bool`, `color`→`vec4`, `point2D`→`vec2`. `image` と `audio` と `audioFFT` は `uniform sampler2D` と 2 の 4 項目を持つ.
- 正確な順序とオフセットは ISFGLSLGenerator の `_assembleShaderSource_VarDeclarations` が決める. isfbench はそれが書き込む `offsetInBuffer()` を使い, 自分で計算しない.
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
- `bool` は 4 バイトの `uint` になる. uniform の値の位置は ISFGLSLGenerator のオフセットを使う. 念のため `--reflect` のオフセットと一致するかを M1 のテストで確かめる.
- 頂点の入力は `VERTEXDATA [[attribute(0)]]`.
- 予約語の再現.
  - 変数名 `layout`: glslang で `syntax error, unexpected LAYOUT, expecting COMMA or SEMICOLON`. VDMX と同じ文言 (検証済み).
  - 関数名 `vertex`: 自作の小さなシェーダーでは, Homebrew の spirv-cross が VIDVOX と同じ引数でも `vertex0` に改名して, Metal でも通ってしまった. VDMX で落ちた理由は未解明 (2.5). Metal の予約語は isfbench が自前で字句検査する (7.2).

## 5. CLI 仕様

```
isfbench check  <shader.fs>... [--json]
isfbench render <shader.fs> --out <dir|file.png> [--frames N] [--at SECONDS] [描画オプション]
isfbench bench  <shader.fs>... [描画オプション] [計測オプション]
isfbench info   <shader.fs> [--size WxH]                 # 短い要約
isfbench dump   <shader.fs> <what> [--size WxH] [--set NAME=VALUE]...
isfbench --version
```

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
| `--glslang PATH` / `--spirv-cross PATH` | `PATH` から探す | 外部コマンド |
| `--keep-intermediates DIR` | なし | 生成した GLSL, SPIR-V, MSL を保存する (デバッグ用) |
| `--from FILE` | なし | シェーダーのパスを 1 行 1 本で読む (`-` で標準入力) |

描画オプション (render と bench).

| オプション | 既定 | 意味 |
|---|---|---|
| `--size WxH` | `1920x1440` | 出力サイズ. vjcomponents のプリセットに合わせた既定 |
| `--fps N` | `60` | 疑似時間の刻み. `TIME = i / N`, `TIMEDELTA = 1 / N`, `FRAMEINDEX = i` |
| `--set NAME=VALUE` | なし | 入力を固定値にする (複数可). `color` は `r,g,b,a`, `point2D` は `x,y` |
| `--levels MODE` | `default` | render での Level 入力の与え方. 6 章 |
| `--recording FILE` | なし | 録音ファイル. 指定すると `recording` モードが使える. vjcomponents では `recordings/vdmx_mic.jsonl` |
| `--level-pattern REGEX` | `^(Level\|Lv)(?![a-z]\|Gain$)` | Level 入力とみなす名前 |
| `--images DIR` | シェーダーの場所から解決 | IMPORTED の基準ディレクトリを上書き |

計測オプション (bench).

| オプション | 既定 | 意味 |
|---|---|---|
| `--warmup N` | `60` | 計測前に空回しするフレーム数 (持続バッファが溜まるまで) |
| `--frames N` | `240` | 計測するフレーム数 |
| `--repeat N` | `1` | 計測を何回繰り返して中央値を取るか |
| `--modes LIST` | `default,max`. `--recording` があれば `default,recording,max` | 6 章のモードをカンマ区切りで. 1 本ずつ全モードを測る |
| `--results FILE` | `.isfbench/results.jsonl` | 結果を 1 行 1 計測で追記する |
| `--compare` | on | 同じシェーダー, 同じ条件の前回の結果との差 (%) を表に出す |
| `--json` | off | 表の代わりに JSON を標準出力に出す |
| `--sort KEY` | `median` | 表の並び順 |

終了コード. 全部成功で 0, いずれかのシェーダーがコンパイルや描画に失敗したら 1, 使い方の誤りは 2.

## 6. 入力の与え方 (Level モード)

GPU コストは入力の値で変わる. Level が 0 (無音または未割り当て) だと描画を省くシェーダーが多く, 実際より軽く出る. 本番でカクつくのは音が大きく描く要素が最も多い瞬間なので, 複数のモードで測る.

- Level 入力とは `--level-pattern` に合う名前の float 入力. vjcomponents の規約では `LevelGain` は Level 入力ではない (パターンが除外する).
- モード.
  - `default`: 全入力が DEFAULT. Level 入力も DEFAULT (vjcomponents では 0). 録音ファイルが無くても使えるので, 単独の CLI としての既定はこれと `max`.
  - `recording`: Level 入力を定義順に `/Filter 1`, `/Filter 2`, ... に割り当て, 足りなければ `n % count + 1` で折り返す (vjcomponents の `tools/vj_controller.py` と preview と同じ). 値は録音を疑似時間で引いた値 × (MAX − MIN) + MIN. ほかの入力は DEFAULT.
  - `max`: Level 入力を MAX にする. ほかは DEFAULT.
- 録音ファイルの形式 (JSON Lines): `{"t": 0.0001, "address": "/Filter 3", "value": 0.768}`. `t` は秒. アドレスごとに時系列を作り, 時刻 `t` 以前の最後の値を使う (直前値保持). 録音の長さで繰り返す. vjcomponents の `preview/audio.ts` の `sampleTrack` が参照実装.
- `event` 入力は常に false. `--set NAME=1` で毎フレーム true にできる.
- `--set` は全モードで最後に適用する.
- `audio` / `audioFFT` 型の入力は 0 で埋めたテクスチャ (幅 512, 高さ 1, 未検証の仮置き) を渡し, 表に注記する.

## 7. 処理の流れ

### 7.1 ISF の読み込み

- 読み込みは ISFGLSLGenerator の `VVISF::CreateISFDocRef(path, true)` に任せる (メタデータの JSON, INPUTS, PASSES, IMPORTED, 同名の `.vs`). 例外 (`VVISF::ISFErr`) は check の失敗 (`stage: parse`) として報告する.
- 入力の一覧, パス, 画像は `ISFDoc` の `inputs()`, `renderPasses()`, `imageImports()` から取る. Level 入力の判定など isfbench 独自の処理はその上に載せる.
- `.vs` の扱いも ISFGLSLGenerator に任せる (`hasCustomVertShader()`).
- `WIDTH` / `HEIGHT` は ISF の式. ISFGLSLGenerator の `ISFPassTarget::evalTargetSize(width, height, symbols)` が exprtk で評価する (入力名を変数として渡す). 自前の評価器は書かない. vjcomponents で実際に使われている形 (2026-11-04 に grep で確認, rejected を含む).
  - 数値: `"1"`, `"4"`, `"48"`, `"512"`, `"1100"` など
  - 出力サイズ: `"$WIDTH"`, `"floor($WIDTH/2.0)"`
  - 入力値を含む: `"floor($WIDTH/$CellSize)"`, `"floor($HEIGHT/($CellSize*0.866))"`
  - 関数の入れ子: `"min($WIDTH, 640)"`, `"max(1, floor($HEIGHT * min(1, 640 / $WIDTH)))"`
- 入力値で大きさが変わるので, ISFMSLKit と同じく毎フレーム評価し, 大きさが変わったらテクスチャを作り直す. 持続バッファの初期内容は 7.3 を参照.
- vjcomponents に `.vs` を持つシェーダーと `FLOAT: true` のパスは今のところ無い (2026-11-04 確認). `audio` 型の入力を持つのは `isfs/sprites/fullmoon.fs` と `isfs/signal/multibandwaves.fs`. IMG 系の関数は `IMG_PIXEL` `IMG_NORM_PIXEL` `IMG_SIZE` `IMG_THIS_PIXEL` が使われ, `IMG_THIS_NORM_PIXEL` は使われていない.

### 7.2 check

1. ISFGLSLGenerator で ISF を読み, `generateShaderSource(&frag, &vert, VVISF::GLVersion_4, true)` で GLSL を作る. 例外は `stage: parse`.
2. glslang で頂点とフラグメントを別々に SPIR-V へ (引数は 2.5 と同じ). 失敗したら `stage: glsl` とエラーを報告する. エラーの行番号は生成した GLSL の行で, VDMX のエラー画面の番号 (`ERR: 111:` など) と同じ数え方. その番号と, 元の .fs の行の両方を出す. 前置きはメタデータのブロックと置き換わるので, 前置きの行数を引くだけでは合わない. 「元の .fs で本体が始まる行 − 生成した GLSL で本体が始まる行」を足す. IMG 系の書き換えは 1 行の中で収まるので, この差は 1 つの定数で済む見込み. ただし ISFGLSLGenerator は `IMG_THIS_PIXEL` 用の宣言なども足すので, 実装時に生成物を見て確かめる.
3. spirv-cross で MSL へ (引数は 2.5 と同じ. 関数名は `VV<ファイル名>VertFunc` / `VV<ファイル名>FragFunc`). 失敗したら `stage: spirv-cross`.
4. `makeLibrary(source:)` で Metal へ. 失敗したら `stage: metal`.
5. 解決できない uniform の検査 (`stage: unbound`). MSL の関数の引数のうち, ISF のホストが値を渡せないもの (シェーダー本体が自分で宣言した `uniform` など) があれば失敗にする. ISFMSLKit の `ISFMSLFindUnboundArgs` と同じ判定にする.
6. 字句検査 (`stage: lint`). spirv-cross が黙って改名してしまう名前を, 元の .fs の識別子から探す. 一覧は少なくとも `vertex fragment kernel device constant thread threadgroup threadgroup_imageblock half ray_data object mesh visible stage_in`. 関数名, 変数名, 入力名のどれでも警告ではなく失敗にする (VDMX で実際に失敗したため).
7. 各段の所要時間 (ms) も出す. VDMX でクリップを読み込むときの重さの目安になる.

### 7.3 描画 (Metal)

ISFMSLKit の `ISFMSLScene.mm` (2.5) に合わせる. 迷ったらそのソースを正とする.

- パスは `renderPasses()` の順. `TARGET` のあるパスはそのバッファへ, 最後のパス (TARGET なし) は出力テクスチャへ描く.
- 頂点データ: パスの描画サイズ W×H のピクセル座標の四角形 (z=0, w=1). 3.1 の射影で NDC に変換される. 頂点の並びと形 (三角形 2 枚か strip か) は ISFMSLKit の `resToQuadVertsDict` を作っている箇所に合わせる.
- 頂点データのバッファ番号は「頂点関数が使う最大のバッファ番号 + 1」. `MTLVertexDescriptor` もその番号で作る. uniform と同じ番号にするとエラーにならず位置がでたらめになる.
- uniform: ISFGLSLGenerator が返す大きさを 48 の倍数に切り上げたバイト列を作る. 先頭 48 バイトが `ISFShaderRenderInfo`, 画像ごとの `ISFShaderImgInfo` と入力の値は `offsetInBuffer()` の位置に書く. パスごとに `PASSINDEX` と `RENDERSIZE` を書き換え, 新しい `MTLBuffer` にコピーして頂点とフラグメントの両方に渡す. 1 つの `MTLBuffer` を使い回すと, GPU が実行する時点の値 (後のパスの `PASSINDEX` など) を読んでしまう. 4 KB 未満なら `setVertexBytes` / `setFragmentBytes` でもよい.
- `ISFShaderImgInfo`: `rect` はテクスチャの中の使う範囲 (普通は 0,0,1,1), `size` はそのピクセル数, `flip` は普通のテクスチャで 1 (2.5).
- パスのテクスチャ: 8 bit は `bgra8Unorm`, `FLOAT` は RGBA の float (ISFMSLKit の `VVMTLPool rgbaFloatTexSized` の形式を確かめて合わせる. 32F の見込み). vjcomponents には 8 bit 前提の値の詰め方をしているシェーダーがある.
- 持続バッファの初期内容 (未検証). ISFGLSLGenerator の `ISFPassTarget.hpp` のコメントには「作ったときに黒で埋める必要がある」とあるが, ISFMSLKit はテクスチャを VVMetalKit の `VVMTLPool` から取り, ロードアクションも `dontCare` で, VVMetalKit のソースにテクスチャを消す処理は見当たらなかった. つまり VDMX でも 1 フレーム目の持続バッファの中身は不定かもしれない. isfbench は結果を毎回同じにするため黒 (0,0,0,0) で埋める. 計測には影響しないが, render の PNG を VDMX と比べるとき (M3) は最初の数フレームが違いうることに注意する.
- 読み書きの入れ替えは ISFMSLKit のやり方に合わせる.
- ロードアクションはカスタムの頂点シェーダーがあるときだけクリア, それ以外は `dontCare` (ISFMSLKit と同じ). 持続でないバッファの初期内容は保証されないので, それに頼るシェーダーは VDMX でも不定になる.
- サンプラー: 正規化座標, 線形補間, 端はクランプ.
- IMPORTED の画像は ImageIO で読んでテクスチャにする. 画素形式と `flip` は ISFMSLKit が画像を読み込む箇所に合わせる.
- 上下の向き (M2 と M3 で必ず確かめる).
  - 形の向き: 3.1 の射影では `VERTEXDATA (0,0)` が NDC の y = +1 (上) に来るので, 正規化座標の y = 1 が出力 PNG の一番上の行になる見込み. M2 で spiral_gratings が preview と上下反転して出たら, 頂点の並べ方が間違っている. テクスチャの反転で補わないこと.
  - テクスチャの向き: `flip = 1` で正しく読めるはず (2.5). 次の検査用シェーダーで確かめる.
  - バッファ: 1 フレーム目に上半分だけ白を書き, 2 フレーム目以降は自分のバッファを `IMG_THIS_PIXEL` で読んで写すシェーダー. 出力の上半分が白なら正しい.
  - 画像: 上半分が白の PNG を IMPORTED で読んで表示するシェーダー.
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

### 7.5 出力

- 標準出力の表 (bench). 列: shader, mode, median ms, p95 ms, passes, 前回比 %, 注記 (audio 入力, 失敗理由など). 既定は median の降順.
- 結果ファイル `.isfbench/results.jsonl` に 1 計測 1 行で追記する.

```json
{"at":"2026-11-04T05:00:00Z","shader":"isfs/lines/random_line.fs","sha256":"<.fs の内容のハッシュ>",
 "git":{"commit":"d7b859b","dirty":true},"size":[1920,1440],"fps":60,"mode":"max",
 "warmup":60,"frames":240,"repeat":1,
 "ms":{"median":3.21,"p95":3.40,"min":3.10,"mean":3.22,"stddev":0.05},
 "compile_ms":{"glsl":12.0,"spirv_cross":8.0,"metal":40.0},
 "device":"Apple M4 Pro","isfbench":"0.1.0"}
```

- 前回比は, 同じ shader パス, size, mode, frames の直近の行と比べる. `sha256` が違えばシェーダーが変わったことが分かる.
- `git` はシェーダーのあるリポジトリで `git rev-parse` と `git status --porcelain` を取る. リポジトリでなければ省く.

## 8. 構成 (SwiftPM)

```
isfbench/
├─ Package.swift                 # swift-tools-version 6.0, macOS 14 以上, 依存は swift-argument-parser だけ
├─ Vendor/
│  └─ ISFGLSLGenerator/          # git submodule. github.com/mrRay/ISFGLSLGenerator を 2b5507b に固定 (BSD 3-Clause)
├─ Sources/
│  ├─ isfbench/                  # 実行ファイル. 引数の解釈と表の出力だけ
│  ├─ CISFGLSLGenerator/         # C++ ターゲット. Vendor の libISFGLSLGenerator/src と include をビルドする
│  ├─ ISFGLSLBridge/             # C++ ターゲット. 下の C 関数を extern "C" で公開する薄い層
│  └─ ISFKit/                    # Swift ライブラリ. 他から再利用できるように分ける
│     ├─ ISFDocument.swift       # ISFGLSLBridge を包む. 入力, パス, 画像, 生成した GLSL, オフセット
│     ├─ Toolchain.swift         # glslang / spirv-cross の呼び出し (2.5 の引数)
│     ├─ MSLSignature.swift      # MSL の関数の宣言から引数の番号を読む (ISFMSLParseFuncSignature 相当) と unbound の検査
│     ├─ Lint.swift              # 7.2 の字句検査
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

- ビルドは `swift build -c release`. 実行ファイルは `.build/release/isfbench`.
- ISFGLSLGenerator は C++ (C++17 以上, exprtk と nlohmann json をヘッダーで含む). Swift から直接 C++ を呼ぶ (C++ 相互運用) より, `ISFGLSLBridge` で必要な操作だけを C の関数にして呼ぶほうが壊れにくい. 例: 文書を開く / 閉じる, GLSL を作る (頂点とフラグメントの文字列, UBO の大きさ), 入力とパスと画像の一覧と各オフセット, パスの大きさの評価, エラー文字列. exprtk はコンパイルが重いので, リリースビルドの時間に注意する.
- ISFGLSLGenerator のビルドに使うコンパイルフラグは, ISFMSLKit の `ISFGLSLGenerator_build_script.sh` と ISFGLSLGenerator の `CMakeLists.txt` を参考にする.
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
- シェーダーごとの変換結果 (MSL) は `.fs` の内容のハッシュで `~/Library/Caches/isfbench/` に保存し, 同じ内容なら再変換しない (チューニングで何度も測るため).

## 9. マイルストーンと完了条件

各段階は前の段階が完了条件を満たしてから進める.

### M0: 骨組み
- Package.swift, `isfbench --version`, `isfbench check --help` が動く.
- ISFGLSLGenerator を submodule で入れ, `CISFGLSLGenerator` と `ISFGLSLBridge` がビルドできる.

### M1: check
- ISFGLSLGenerator で GLSL を作り, 4 章の経路で Metal までコンパイルする. 7.2 の unbound 検査と字句検査も入れる.
- 完了条件.
  0. vjcomponents の line_space の修正前の版 (下の 2.) で `dump glsl-frag` した出力が, 3 章の写し (VDMX のエラー画面) と空白を除いて一致する. ISFGLSLGenerator の組み込みが VDMX と同じものを出す証拠になる.
  1. vjcomponents の `isfs/lines/line_space.fs` (現在の版) が全段成功.
  2. line_space の修正前の版が `stage: glsl` で失敗し, メッセージに `unexpected LAYOUT` を含む. 取り出し方: vjcomponents で `git show d7b859b~1:isfs/lines/line_space.fs`.
  3. thin_barcode の修正前の版が同じく失敗する (`git show 2798e10~1:isfs/lines/thin_barcode.fs`). 入力名が原因の例.
  4. super_polygons の修正前の版 (`git show 5d195dd~1:isfs/depth/super_polygons.fs`. 関数 `vec2 vertex(float column, float row)` を持つ) が `stage: lint` で失敗する. あわせて, 字句検査を外したときに spirv-cross と Metal の段で通るか落ちるかを記録し, 2.5 の未解明の点に結果を書き足す.
  5. vjcomponents の `isfs/` 以下 (rejected を除く) 全部を check して, 失敗の一覧を出す. VDMX で普通に読み込めているシェーダーが失敗したら, isfbench 側の呼び出し方 (引数, 組み込み方) をまず疑う.
  6. エラーの行番号が元の .fs の行と一致する.
  7. `--reflect` で得た `VVISF_UNIFORMS` のオフセットが, ISFGLSLGenerator の `offsetInBuffer()` と一致する (数本で確かめてテストに残す).

- `info` と `dump` も M1 で作る (check の生成物をそのまま出すだけなので). 完了条件: `dump glsl-frag` の出力が 3 章の形と一致する.

### M2: 1 パスの描画
- 1 パスのシェーダーを `render` で PNG にする.
- 完了条件: vjcomponents の `isfs/geometry/spiral_gratings.fs` などパスの無いシェーダーを 1 枚出し, preview で同じ時刻を見たものと形が同じ (上下左右の向きを含む). 半画素の差は許す.

### M3: 複数パス, 持続バッファ, 画像
- 7.3 の向きの検査用シェーダー 2 本で `_X_flip` の扱いを決め, テストに残す.
- 完了条件: `line_space.fs` (幅 4 の持続バッファ), `ripple_shapes.fs` (幅 48 の持続バッファと IMPORTED 画像), `random_line.fs` (出力と同じ大きさの持続バッファ) が, 数十フレーム進めた PNG で preview と同じように見える.

### M4: bench
- 7.4 と 7.5 と 6 章を実装する.
- 完了条件.
  1. 何もしないシェーダーが 1 ms を大きく下回る.
  2. 同じシェーダーを 3 回測って中央値のばらつきが 5% 以内.
  3. vjcomponents で重いと分かっているものが上位に来る. 参考: preview (1280x720, WebGL) では ripple_shapes の Shard が約 13 fps, gravity_flow が約 17 fps, randomgravities が約 20 fps, Circle の ripple_shapes が約 68 fps だった.
  4. `--modes recording,max` で, Level で描く量が変わるシェーダー (例: `isfs/signal/polar_waveform.fs`, `isfs/signal/data_matrix.fs`) は max のほうが重く出る.

### M5: 仕上げ
- README (インストール, 例, 数字の読み方と限界).
- vjcomponents の Use 済みシェーダーを全部測る例. Use 済みの一覧は vjcomponents の preview サーバーの `GET /__feedback` か `isfs/feedback.jsonl` (ファイル名ごとに最後の `use` / `unuse` / `reject` が効く) から作れる. isfbench 本体はこの規則を知らなくてよい (`--from` で一覧を渡す).

## 10. 未決事項とリスク

- **glslang と SPIRV-Cross の版の違い**. isfbench は Homebrew の版を使うが, VDMX は VIDVOX が改造した古い版を使う. `vertex` のように結果が変わる例がある (2.5). 対策の候補は 3 つで, ユーザーの判断待ち.
  1. Homebrew の版を使い, 違いは字句検査で補う (今の方針で, M0 はこれで始める. 2 と 3 は後から差し替えられ, 構成は変わらない).
  2. VIDVOX の改造版 (`mrRay/glslang` の `GLSLangValidatorLib` ブランチ, `mrRay/SPIRV-Cross` の `SPIRVCrossLib` ブランチ) をソースからビルドして使う. VDMX に最も近いが, ビルドが重い.
  3. ISFMSLKit の `extern/` に同梱されたビルド済みの dylib を呼ぶ. 手軽だが, 外部のビルド済みバイナリを実行することになる. ISFMSLKit のライセンスは GitHub 上で判定されていない (NOASSERTION) ので, 配布するなら確認が要る.
- VDMX6 が使っているのが公開版の ISFMSLKit そのものかは分からない (社内で手を入れている可能性がある). VDMX で落ちて isfbench で通るシェーダーが見つかったら, エラー画面の GLSL を 3 章に追記し, check のテストに足す.
- `audio` / `audioFFT` 入力のテクスチャの形 (幅, 高さ, 形式) は ISFMSLKit のソースで確かめる.
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

### vjcomponents 内

- `AGENTS.md`: ISF の規約 (Level 入力, 予約語の一覧, 出力の RGB を alpha 0 で 0 にすること).
- `preview/shader.ts`: IMG_* の書き換えの参照実装 (WebGL 用なので書き換え先は違う).
- `preview/renderer.ts`: パスと持続バッファの扱いの参照実装.
- `preview/audio.ts`: 録音の読み込みと直前値保持.
- `recordings/vdmx_mic.jsonl`: VDMX の Audio Analysis を OSC で記録したもの (約 47 値/秒, 30 秒).
- `tools/vj_controller.py`: Level 入力を Filter に割り当てる規則.
