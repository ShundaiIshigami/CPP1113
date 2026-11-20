// 今回追加した定数バッファ
cbuffer CBParam : register(b0)
{
    float4 baseColor;
};

// ----------------------------------------------------------
// 頂点
// ----------------------------------------------------------
// カメラ定数バッファ
cbuffer VSConstants : register(b8)
{
    float4x4 view;
    float4x4 projection;
    float3 cameraPosW;
    float cameraNear;
    float3 cameraForwardW;
    float cameraFar;
    float4 time; // (t, dt, 1/dt, frameCount)
};

// 行列・シャドウ定数バッファ（b9 の名前重複を解消）
cbuffer CBWorld : register(b9)
{
    float4x4 world;
    float4x4 lightViewProj; // ライト視点の View * Projection 行列
};

// 頂点シェーダーへ入力するデータ
struct VSInput
{
    float3 pos : POSITION;
    float3 nrm : NORMAL;
    float2 uv : TEXCOORD0;
};

// 頂点シェーダーから出力するデータ＝ピクセルシェーダーに入力するデータ
struct PSInput
{
    float4 posH : SV_Position; // 頂点の座標(射影座標系)
    float3 posW : TEXCOORD0; // ワールド座標
    half3 nrmW : TEXCOORD1; // ワールド法線
    half2 uv : TEXCOORD2; // UV座標
};

// 頂点シェーダー
PSInput VS(VSInput vin)
{
    PSInput Out;
    float4 p = float4(vin.pos.xyz, 1.0f);
    p = mul(world, p); // ワールド変換
    Out.posW = (float3)p;

    p = mul(view, p); // ビュー変換
    p = mul(projection, p); // プロジェクション変換
    Out.posH = p;

    float3x3 world3x3 = (float3x3)world;
    Out.nrmW = (half3)mul(world3x3, vin.nrm);

    Out.uv = vin.uv;

    return Out;
}

// ----------------------------------------------------------
// ピクセル
// ----------------------------------------------------------
// ライト
cbuffer LightPerFrame : register(b11)
{
    float4 ambientColor;
    float4 directionalColor;
    float3 directionW;
    uint pad;
};

struct PointLight
{
    float4 color;
    float3 positionW;
    float rangeInv;
};

struct SpotLight
{
    float4 color;
    float3 positionW;
    float rangeInv;
    float3 directionW;
    float outerCos;
};

cbuffer LightPerObject : register(b12)
{
    PointLight pointLights[8]; // 最大8個
    SpotLight spotLights[8]; // 最大8個
    uint pointLightCount;
    uint spotLightCount;
    float2 _pad; // 16byte 境界合わせ
};

// テクスチャとサンプラ。4番のテクスチャスロットとサンプラスロットを使用（UNIDX_PS_SLOT_ALBEDO）
Texture2D texture0 : register(t4);
SamplerState sampler0 : register(s4);

// シャドウマップ用テクスチャとサンプラ（例: t5, s5）
Texture2D<float> shadowMap : register(t5);
SamplerComparisonState shadowSampler : register(s5);

// 影の計算（0.0: 影, 1.0: 光が当たる）
float CalcShadow(float3 posW, float3 N, float3 L)
{
    float4 lightPosH = mul(lightViewProj, float4(posW, 1.0f));
    float3 projCoords = lightPosH.xyz / lightPosH.w;

    // クリップ空間 (-1..1) -> UV空間 (0..1)（DirectXはYが反転）
    float2 shadowUV;
    shadowUV.x = projCoords.x * 0.5f + 0.5f;
    shadowUV.y = -projCoords.y * 0.5f + 0.5f;

    // シャドウマップ範囲外は影なし扱い
    if (shadowUV.x < 0.0f || shadowUV.x > 1.0f ||
        shadowUV.y < 0.0f || shadowUV.y > 1.0f ||
        projCoords.z < 0.0f || projCoords.z > 1.0f)
    {
        return 1.0f;
    }

    // シャドウアクネ（縞模様のノイズ）防止のバイアス
    float bias = max(0.002f * (1.0f - saturate(dot(N, L))), 0.0005f);
    return shadowMap.SampleCmpLevelZero(shadowSampler, shadowUV, projCoords.z - bias);
}

// ピクセルシェーダー
half4 PS(PSInput In) : SV_Target0
{
    // テクスチャから色を取得
    half4 albedo = texture0.Sample(sampler0, In.uv);

// 明示的に法線を正規化（モデルスケール非均等だと崩れるため）
half3 N = normalize(In.nrmW);
half3 L = normalize(-directionW);
half3 V = normalize(cameraPosW - In.posW);
half3 H = normalize(L + V);

// 影の係数を取得
half shadow = (half)CalcShadow(In.posW, N, L);

// 環境光（影の中でも最低限見えるベース）
half3 diffAccum = ambientColor.rgb;
half3 specAccum = 0;

// ディレクショナルライト（拡散＋鏡面）に影を反映
half NdotL = saturate(dot(N, L));
half3 dirSpec = directionalColor.rgb * pow(saturate(dot(N, H)), 100) * NdotL;
diffAccum += directionalColor.rgb * NdotL * shadow;
specAccum += dirSpec * shadow;

// ポイントライト
[loop]
for (uint i = 0; i < pointLightCount; ++i)
{
    float3 toLight = pointLights[i].positionW - In.posW;
    float dist = length(toLight);
    half3 plDir = (dist > 0.0001f) ? (half3)(toLight / dist) : half3(0, 1, 0);

    half plNdotL = saturate(dot(N, plDir));
    half atten = saturate(1.0f - (dist * pointLights[i].rangeInv));
    atten = atten * atten;

    half3 plH = normalize(plDir + V);
    diffAccum += pointLights[i].color.rgb * atten * plNdotL;
    specAccum += pointLights[i].color.rgb * atten * pow(saturate(dot(N, plH)), 100) * plNdotL;
}

// カラー合成
half3 litColor = diffAccum * albedo.rgb * baseColor.rgb + specAccum * baseColor.rgb;

// 最終カラーを出力
return half4(litColor, albedo.a * baseColor.a);
}