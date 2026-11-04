# isfbench 設計書

ISF (Interactive Shader Format) シェーダーを VDMX6 Plus と同じ経路 (GLSL 4.00 → SPIR-V → Metal) で検査し, 描画し, GPU 時間を測る macOS 用の CLI.
この文書だけを読んで別セッションが実装を始められることを目指す. 既に手元で確かめたことは「検証済み」, 確かめていない推測は「未検証」と書き分ける.

## 0. 現状 (2026-11-04)

- 実装はまだ何も無い. M0 から始める.
- このマシンには Homebrew で glslang と spirv-cross を入れた (2.).
- 4 章の変換経路は一時ディレクトリで試しただけで, ファイルは残していない.
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

## 3. VDMX が組み立てる GLSL (検証済みの写し)

VDMX のエラー画面に出た, line_space.fs と thin_barcode.fs から VDMX が生成した GLSL をそのまま写す. isfbench はこれと同じものを生成する. 空白はエラー画面の表示で崩れているので整えた.

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

### 3.3 本体の書き換え (観測できた分)

| 元 | VDMX の生成物 | 根拠 |
|---|---|---|
| `IMG_PIXEL(lineState, vec2(1.5, 0.5))` | `VVSAMPLER_2DBYPIXEL(lineState, _lineState_imgRect, _lineState_imgSize, (_lineState_flip), vec2(1.5, 0.5))` | 検証済み (line_space) |
| `gl_FragCoord.x` | `isf_FragCoord.x` | 検証済み (line_space の pass 0) |
| `IMG_NORM_PIXEL(x, c)` | `VVSAMPLER_2DBYNORM(x, _x_imgRect, _x_imgSize, (_x_flip), c)` | 未検証. BYNORM が前置きにあるので, こう書き換えると推測 |
| `IMG_THIS_PIXEL(x)` | `VVSAMPLER_2DBYPIXEL(x, ..., isf_FragCoord)` 相当 | 未検証 |
| `IMG_THIS_NORM_PIXEL(x)` | `VVSAMPLER_2DBYNORM(x, ..., isf_FragNormCoord)` 相当 | 未検証 |
| `IMG_SIZE(x)` | `_x_imgSize` | 未検証 |

- 括弧が入れ子になった引数の扱いは vjcomponents の `preview/shader.ts` の `expandImageFunctions` が参考になる (コメント内は書き換えない, 最初の引数はサンプラー名, 残りは座標).
- `gl_FragCoord` は `isf_FragCoord` に置き換わるが, 値は `gl_FragCoord` と同じ画素の中心 (x + 0.5, y + 0.5) になる. `isf_FragCoord` は頂点シェーダーの出力で, 頂点 (四隅) では `isf_FragNormCoord * RENDERSIZE` がちょうど 0 か W / H なので `floor` は何もしない. その値が面の中で線形に補間され, 画素の中心で評価される. 半画素のずれは無いので, 描画側で補正しないこと.

### 3.4 uniform ブロックの並び (検証済み)

1. 固定の 7 個: `int PASSINDEX; float TIME; vec2 RENDERSIZE; vec4 DATE; float TIMEDELTA; int FRAMEINDEX; vec2 PADDING_INFO;`
2. 画像ごと (パスのバッファ → IMPORTED → image 型の入力の順と推測. 順序は未検証): `vec4 _X_imgRect; vec2 _X_imgSize; bool _X_flip; int _X_padding;`
3. INPUTS を定義順に. 型の対応は `float`→`float`, `long`→`int`, `bool`→`bool`, `event`→`bool`, `color`→`vec4`, `point2D`→`vec2`. `image` と `audio` と `audioFFT` は `uniform sampler2D` と 2 の 4 項目を持つ (未検証).
- `thin_barcode.fs` では入力の `long` が `int layout;` としてブロックに入っていた. 入力名がそのままメンバー名になるので, 予約語の入力名も glslang で検出できる.
- サンプラーはブロックの外に `uniform sampler2D X;` として並ぶ.

## 4. 手元で確かめた変換経路 (検証済み)

3 の形の line_space を使い, 次のコマンドで全段が通った.

```sh
glslang -G --auto-map-bindings --auto-map-locations -S vert -o vert.spv isf.vert
glslang -G --auto-map-bindings --auto-map-locations -S frag -o frag.spv isf.frag
spirv-cross frag.spv --reflect                          # JSON. uniform のオフセットと binding
spirv-cross frag.spv --msl --msl-version 20100 --msl-decoration-binding --output frag.metal
spirv-cross vert.spv --msl --msl-version 20100 --msl-decoration-binding --output vert.metal
# Swift から MTLDevice.makeLibrary(source:) で frag.metal と vert.metal をコンパイル (OK)
```

分かったこと.

- `-G` は OpenGL 意味論の SPIR-V. `precision` 修飾子や std140 のブロックをそのまま受け付けた.
- 頂点とフラグメントは別々にコンパイルする (2 つを 1 回のコマンドに渡すと出力が 1 ファイルになり, どちらの段か分かりにくい).
- binding は段ごとに違う. 頂点は `VVISF_UNIFORMS` が binding 0, フラグメントは texture `lineState` が 0 で `VVISF_UNIFORMS` が 1 だった. MSL では頂点が `[[buffer(0)]]`, フラグメントが `[[buffer(1)]]`, `[[texture(0)]]`, `[[sampler(0)]]`. 決め打ちせず reflect の JSON から読む.
- reflect の `types` に `VVISF_UNIFORMS` の各メンバーの `offset` と `block_size` (line_space は 104) が出る. `bool` は `uint` (4 バイト) として出る. Swift 側はこの offset に従って値を詰める. std140 を手で計算しない.
- 頂点の MSL は `vertex main0_out main0(main0_in in [[stage_in]], constant VVISF_UNIFORMS& _20 [[buffer(0)]])`, 入力は `VERTEXDATA [[attribute(0)]]`. フラグメントの関数名も `main0`.
- 予約語の再現.
  - 変数名 `layout`: glslang で `syntax error, unexpected LAYOUT, expecting COMMA or SEMICOLON`. VDMX と同じ文言 (検証済み).
  - 関数名 `vertex`: spirv-cross が `vertex0` に改名して Metal でも通ってしまう. VDMX は通らなかったので, VDMX の Metal 変換は spirv-cross の既定とは違う. よって Metal の予約語は isfbench が自前で字句検査する (7.2).

## 5. CLI 仕様

```
isfbench check  <shader.fs>... [--json]
isfbench render <shader.fs> --out <dir|file.png> [--frames N] [--at SECONDS] [描画オプション]
isfbench bench  <shader.fs>... [描画オプション] [計測オプション]
isfbench info   <shader.fs>            # メタデータ, 生成した GLSL, uniform の配置を表示
isfbench --version
```

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

- 先頭の `/*{ ... }*/` を JSON として読む (vjcomponents では厳密な JSON). 読めなければ check の失敗として報告する.
- 使う項目: `INPUTS` (`NAME`, `TYPE`, `DEFAULT`, `MIN`, `MAX`, `VALUES`, `LABELS`), `PASSES` (`TARGET`, `PERSISTENT`, `FLOAT`, `WIDTH`, `HEIGHT`), `IMPORTED` (`PATH`).
- `.fs` と同じ場所の同名 `.vs` があれば, それを頂点シェーダー本体として使う. このとき前置き (3.1 の `main` より前) はそのまま付け, 本体に `isf_vertShaderInit()` の定義を足す. VDMX の正確な挙動は未検証.
- `WIDTH` / `HEIGHT` は ISF の式. vjcomponents で実際に使われている形 (2026-11-04 に grep で確認, rejected を含む).
  - 数値: `"1"`, `"4"`, `"48"`, `"512"`, `"1100"` など
  - 出力サイズ: `"$WIDTH"`, `"floor($WIDTH/2.0)"`
  - 入力値を含む: `"floor($WIDTH/$CellSize)"`, `"floor($HEIGHT/($CellSize*0.866))"`
  - 関数の入れ子: `"min($WIDTH, 640)"`, `"max(1, floor($HEIGHT * min(1, 640 / $WIDTH)))"`
- 式の評価器を自前で書く. 対応するのは数値, `$WIDTH` `$HEIGHT` (最終出力のサイズ), `$<入力名>` (その時点の入力値. bool は 0/1), `+ - * /`, 単項マイナス, 括弧, `floor ceil round min max abs`. 結果は floor して 1 以上にする. 入力値で大きさが変わるので, 毎フレーム評価して変わったらバッファを作り直す (中身は 0 に戻る. VDMX での挙動は未検証).
- vjcomponents に `.vs` を持つシェーダーと `FLOAT: true` のパスは今のところ無い (2026-11-04 確認). `audio` 型の入力を持つのは `isfs/sprites/fullmoon.fs` と `isfs/signal/multibandwaves.fs`. IMG 系の関数は `IMG_PIXEL` `IMG_NORM_PIXEL` `IMG_SIZE` `IMG_THIS_PIXEL` が使われ, `IMG_THIS_NORM_PIXEL` は使われていない.

### 7.2 check

1. GLSL を生成する (3 章).
2. glslang で頂点とフラグメントを別々に SPIR-V へ. 失敗したら `stage: glsl` とエラーを報告する. エラーの行番号は生成した GLSL の行なので, 元の .fs の行に戻して併記する. 前置きはメタデータのブロックと置き換わるので, 前置きの行数を引くだけでは合わない. 「元の .fs で本体が始まる行 − 生成した GLSL で本体が始まる行」を足す. IMG 系の書き換えは 1 行の中で収まるので, この差は 1 つの定数で済む.
3. spirv-cross で MSL へ. 失敗したら `stage: spirv-cross`.
4. `makeLibrary(source:)` で Metal へ. 失敗したら `stage: metal`.
5. 字句検査 (`stage: lint`). spirv-cross が黙って改名してしまう名前を, 元の .fs の識別子から探す. 一覧は少なくとも `vertex fragment kernel device constant thread threadgroup threadgroup_imageblock half ray_data object mesh visible stage_in`. 関数名, 変数名, 入力名のどれでも警告ではなく失敗にする (VDMX で実際に失敗したため).
6. 各段の所要時間 (ms) も出す. VDMX でクリップを読み込むときの重さの目安になる.

### 7.3 描画 (Metal)

- 頂点データ: パスの描画サイズ W×H のピクセル座標で 2 枚の三角形 (`(0,0) (W,0) (0,H) (W,H)`, z=0, w=1). 3.1 の射影で NDC に変換される.
- パスは `PASSES` の順. `TARGET` のあるパスはそのバッファへ, 最後のパス (TARGET なし) は出力テクスチャへ描く. `PASSES` が無いシェーダーは 1 パス.
- 各パスで uniform を詰め直す. `PASSINDEX`, そのパスの `RENDERSIZE`, 各バッファの `_X_imgSize` (そのバッファの大きさ), `_X_imgRect = (0,0,1,1)`, `_X_flip`.
- バッファの形式は `rgba8Unorm`. `FLOAT: true` のときだけ `rgba32Float` (16F か 32F かは未検証. まず 32F). vjcomponents には 8 bit 前提の値の詰め方をしているシェーダーがある.
- 持続バッファ (`PERSISTENT: true`) は読み用と書き用の 2 枚を交互に使い, パスを描き終えたら入れ替える. 持続でないバッファも, 同じフレーム内の後のパスから読めるようにする.
- 初期状態は全バッファ (0,0,0,0).
- サンプラーは線形補間, 端はクランプ. 状態を画素の中心 (`x + 0.5`) で読むシェーダーはどちらでも同じ値になる.
- IMPORTED の画像は ImageIO で読んで `rgba8Unorm` のテクスチャにする. パスはシェーダーのファイルからの相対パス.
- 頂点データは `MTLVertexDescriptor` で `[[stage_in]]` に渡す. 頂点段の `VVISF_UNIFORMS` が `[[buffer(0)]]` を使うので, 頂点データのバッファ番号は別にする (例 30). 同じ番号にするとエラーにならず位置がでたらめになる.
- uniform は `setVertexBytes` / `setFragmentBytes` でパスごとに渡す (ブロックは 100 バイト程度で 4 KB の上限に収まる). 1 つの `MTLBuffer` を使い回すと, GPU が実行する時点の値 (後のパスの `PASSINDEX` など) を読んでしまう.
- 上下の向き (未検証. M2 と M3 で必ず確かめる).
  - 形の向き: 3.1 の射影では `VERTEXDATA (0,0)` が NDC の y = +1 (上) に来るので, 正規化座標の y = 1 が出力 PNG の一番上の行になる. M2 で spiral_gratings が上下反転して出たら, 頂点の並べ方が間違っている. テクスチャの反転で補わないこと.
  - テクスチャの向き: Metal では NDC の y = +1 がテクスチャの 0 行目に書かれ, v = 0 で 0 行目を読む. ISF は正規化座標の y = 1 を上とするので, 自分で描いたバッファも, ImageIO で上の行から読み込んだ IMPORTED 画像も, `_X_flip = true` になる見込み. `_X_flip` はこの差を吸収するための uniform と推測する. 次の検査用シェーダーで確かめる. 結果が見込みと違ったら, まず頂点の向きを疑う.
  - バッファ: 1 フレーム目に上半分だけ白を書き, 2 フレーム目以降は自分のバッファを `IMG_THIS_PIXEL` で読んで写すシェーダー. 出力の上半分が白なら正しい.
  - 画像: 上半分が白の PNG を IMPORTED で読んで表示するシェーダー.
- 出力は `--size` の `rgba8Unorm`. render は PNG に書き出す (straight alpha. ISF の出力は RGB が 0 のところ alpha 0 という前提).

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
├─ Sources/
│  ├─ isfbench/                  # 実行ファイル. 引数の解釈と表の出力だけ
│  └─ ISFKit/                    # ライブラリ. 他から再利用できるように分ける
│     ├─ ISFDocument.swift       # メタデータの読み込み, 入力とパスの型
│     ├─ GLSLBuilder.swift       # 3 章の前置きと本体の書き換え, 行番号の対応表
│     ├─ Toolchain.swift         # glslang / spirv-cross の呼び出しと reflect JSON の解釈
│     ├─ Lint.swift              # 7.2 の字句検査
│     ├─ UniformLayout.swift     # reflect の offset に従って値を詰める
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
- `swift-tools-version 6.0` だと Swift 6 の厳密な並行性検査が有効になり, Metal のオブジェクトが `Sendable` でないことで大量の診断が出る. 各ターゲットに `swiftLanguageModes: [.v5]` を付ける.
- swift-argument-parser を使う (サブコマンドとヘルプの手間を省くため). 取得にネットワークが要る.
- 外部コマンドの呼び出しは `Process`. 中間ファイルは一時ディレクトリに置き, `--keep-intermediates` のときだけ残す.
- シェーダーごとの変換結果 (MSL) は `.fs` の内容のハッシュで `~/Library/Caches/isfbench/` に保存し, 同じ内容なら再変換しない (チューニングで何度も測るため).

## 9. マイルストーンと完了条件

各段階は前の段階が完了条件を満たしてから進める.

### M0: 骨組み
- Package.swift, `isfbench --version`, `isfbench check --help` が動く.

### M1: check
- 3 章の GLSL を生成し, 4 章の経路で Metal までコンパイルする. 7.2 の字句検査も入れる.
- 完了条件.
  1. vjcomponents の `isfs/lines/line_space.fs` (現在の版) が全段成功.
  2. line_space の修正前の版が `stage: glsl` で失敗し, メッセージに `unexpected LAYOUT` を含む. 取り出し方: vjcomponents で `git show d7b859b~1:isfs/lines/line_space.fs`.
  3. thin_barcode の修正前の版が同じく失敗する (`git show 2798e10~1:isfs/lines/thin_barcode.fs`). 入力名が原因の例.
  4. 関数名を `vertex` にしたシェーダーが `stage: lint` で失敗する.
  5. vjcomponents の `isfs/` 以下 (rejected を除く) 全部を check して, 失敗の一覧を出す. 失敗があれば 3 章の推測 (IMG_* の書き換えなど) が間違っていないかをまず疑う.
  6. エラーの行番号が元の .fs の行と一致する.

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

- VDMX の Metal 変換の中身は分からない. spirv-cross で通っても VDMX で落ちる例がまだあるかもしれない. VDMX で落ちたシェーダーが見つかったら, エラー画面の GLSL を 3 章に追記し, check のテストに足す.
- 3 章の未検証の書き換え (IMG_NORM_PIXEL など) は, VDMX でエラーを起こしたときに表示される GLSL で確かめられる. わざと 1 行壊したシェーダーを VDMX で読み込ませれば全文が見られる.
- VDMX の `FLOAT` バッファの精度, 画像の順序, `_X_padding` の意味, `audio` 入力の形は未検証.
- GPU 時間は VDMX の出力 fps と一致しない (VDMX は合成, レイヤー FX, Syphon 出力も描く). 順位付けと前後比較に使う.
- Apple GPU はタイルベースなので, パスの多いシェーダーはパスごとのロードとストアのコストも乗る. これは VDMX でも同じなので, そのまま測る.
- 熱で GPU のクロックが下がると数字がぶれる. 長い一括計測では `--repeat` と並び順の工夫で見分ける.

## 11. 背景の資料 (vjcomponents 内)

- `AGENTS.md`: ISF の規約 (Level 入力, 予約語の一覧, 出力の RGB を alpha 0 で 0 にすること).
- `preview/shader.ts`: IMG_* の書き換えの参照実装 (WebGL 用なので書き換え先は違う).
- `preview/renderer.ts`: パスと持続バッファの扱いの参照実装.
- `preview/audio.ts`: 録音の読み込みと直前値保持.
- `recordings/vdmx_mic.jsonl`: VDMX の Audio Analysis を OSC で記録したもの (約 47 値/秒, 30 秒).
- `tools/vj_controller.py`: Level 入力を Filter に割り当てる規則.
