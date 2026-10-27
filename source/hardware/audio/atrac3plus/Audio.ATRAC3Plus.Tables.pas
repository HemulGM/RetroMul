unit Audio.ATRAC3Plus.Tables;
// Native data translation of Jpcsp / FFmpeg ATRAC3+ tables.
// GPL-3.0-or-later. Jpcsp contributors; FFmpeg codec by Maxim Poliakovski.

interface

uses
  System.SysUtils;

type
  TATSpecCodeTab = record
    GroupSize, NumCoeffs, Bits, Redirect: Integer;
    IsSigned: Boolean;
    CB, Xlat: TArray<Integer>;
    class function Create(GroupSize, NumCoeffs, Bits, IsSigned, Redirect: Integer; const CB, Xlat: TArray<Integer>): TATSpecCodeTab; static;
  end;

var
  huff_a01_cb: TArray<Integer>;
  huff_a01_xlat: TArray<Integer>;
  huff_a02_cb: TArray<Integer>;
  huff_a02_xlat: TArray<Integer>;
  huff_a03_cb: TArray<Integer>;
  huff_a03_xlat: TArray<Integer>;
  huff_a04_cb: TArray<Integer>;
  huff_a04_xlat: TArray<Integer>;
  huff_a05_cb: TArray<Integer>;
  huff_a05_xlat: TArray<Integer>;
  huff_a06_cb: TArray<Integer>;
  huff_a06_xlat: TArray<Integer>;
  huff_a07_cb: TArray<Integer>;
  huff_a07_xlat: TArray<Integer>;
  huff_a11_cb: TArray<Integer>;
  huff_a11_xlat: TArray<Integer>;
  huff_a12_cb: TArray<Integer>;
  huff_a12_xlat: TArray<Integer>;
  huff_a13_cb: TArray<Integer>;
  huff_a13_xlat: TArray<Integer>;
  huff_a14_cb: TArray<Integer>;
  huff_a14_xlat: TArray<Integer>;
  huff_a15_cb: TArray<Integer>;
  huff_a15_xlat: TArray<Integer>;
  huff_a16_cb: TArray<Integer>;
  huff_a16_xlat: TArray<Integer>;
  huff_a17_cb: TArray<Integer>;
  huff_a17_xlat: TArray<Integer>;
  huff_a21_cb: TArray<Integer>;
  huff_a21_xlat: TArray<Integer>;
  huff_a22_cb: TArray<Integer>;
  huff_a22_xlat: TArray<Integer>;
  huff_a23_cb: TArray<Integer>;
  huff_a23_xlat: TArray<Integer>;
  huff_a24_cb: TArray<Integer>;
  huff_a25_cb: TArray<Integer>;
  huff_a25_xlat: TArray<Integer>;
  huff_a26_cb: TArray<Integer>;
  huff_a26_xlat: TArray<Integer>;
  huff_a27_cb: TArray<Integer>;
  huff_a27_xlat: TArray<Integer>;
  huff_a31_cb: TArray<Integer>;
  huff_a31_xlat: TArray<Integer>;
  huff_a32_cb: TArray<Integer>;
  huff_a32_xlat: TArray<Integer>;
  huff_a33_cb: TArray<Integer>;
  huff_a33_xlat: TArray<Integer>;
  huff_a34_cb: TArray<Integer>;
  huff_a34_xlat: TArray<Integer>;
  huff_a35_cb: TArray<Integer>;
  huff_a35_xlat: TArray<Integer>;
  huff_a36_cb: TArray<Integer>;
  huff_a36_xlat: TArray<Integer>;
  huff_a37_cb: TArray<Integer>;
  huff_a37_xlat: TArray<Integer>;
  huff_a41_cb: TArray<Integer>;
  huff_a41_xlat: TArray<Integer>;
  huff_a42_cb: TArray<Integer>;
  huff_a42_xlat: TArray<Integer>;
  huff_a43_cb: TArray<Integer>;
  huff_a43_xlat: TArray<Integer>;
  huff_a44_cb: TArray<Integer>;
  huff_a44_xlat: TArray<Integer>;
  huff_a45_cb: TArray<Integer>;
  huff_a45_xlat: TArray<Integer>;
  huff_a46_cb: TArray<Integer>;
  huff_a46_xlat: TArray<Integer>;
  huff_a47_cb: TArray<Integer>;
  huff_a47_xlat: TArray<Integer>;
  huff_a51_cb: TArray<Integer>;
  huff_a51_xlat: TArray<Integer>;
  huff_a52_cb: TArray<Integer>;
  huff_a52_xlat: TArray<Integer>;
  huff_a53_xlat: TArray<Integer>;
  huff_a54_cb: TArray<Integer>;
  huff_a54_xlat: TArray<Integer>;
  huff_a55_cb: TArray<Integer>;
  huff_a55_xlat: TArray<Integer>;
  huff_a56_cb: TArray<Integer>;
  huff_a56_xlat: TArray<Integer>;
  huff_a57_cb: TArray<Integer>;
  huff_a57_xlat: TArray<Integer>;
  huff_a61_cb: TArray<Integer>;
  huff_a61_xlat: TArray<Integer>;
  huff_a62_cb: TArray<Integer>;
  huff_a62_xlat: TArray<Integer>;
  huff_a63_cb: TArray<Integer>;
  huff_a63_xlat: TArray<Integer>;
  huff_a64_cb: TArray<Integer>;
  huff_a64_xlat: TArray<Integer>;
  huff_a65_cb: TArray<Integer>;
  huff_a65_xlat: TArray<Integer>;
  huff_a66_cb: TArray<Integer>;
  huff_a66_xlat: TArray<Integer>;
  huff_a67_cb: TArray<Integer>;
  huff_a67_xlat: TArray<Integer>;
  huff_a71_cb: TArray<Integer>;
  huff_a72_cb: TArray<Integer>;
  huff_a72_xlat: TArray<Integer>;
  huff_a73_cb: TArray<Integer>;
  huff_a73_xlat: TArray<Integer>;
  huff_a74_cb: TArray<Integer>;
  huff_a74_xlat: TArray<Integer>;
  huff_a75_cb: TArray<Integer>;
  huff_a75_xlat: TArray<Integer>;
  huff_a76_cb: TArray<Integer>;
  huff_a76_xlat: TArray<Integer>;
  huff_b01_cb: TArray<Integer>;
  huff_b01_xlat: TArray<Integer>;
  huff_b02_cb: TArray<Integer>;
  huff_b02_xlat: TArray<Integer>;
  huff_b03_cb: TArray<Integer>;
  huff_b03_xlat: TArray<Integer>;
  huff_b04_cb: TArray<Integer>;
  huff_b04_xlat: TArray<Integer>;
  huff_b05_cb: TArray<Integer>;
  huff_b05_xlat: TArray<Integer>;
  huff_b07_cb: TArray<Integer>;
  huff_b07_xlat: TArray<Integer>;
  huff_b12_cb: TArray<Integer>;
  huff_b12_xlat: TArray<Integer>;
  huff_b14_cb: TArray<Integer>;
  huff_b14_xlat: TArray<Integer>;
  huff_b16_cb: TArray<Integer>;
  huff_b16_xlat: TArray<Integer>;
  huff_b26_cb: TArray<Integer>;
  huff_b26_xlat: TArray<Integer>;
  huff_b32_cb: TArray<Integer>;
  huff_b32_xlat: TArray<Integer>;
  huff_b33_cb: TArray<Integer>;
  huff_b33_xlat: TArray<Integer>;
  huff_b35_cb: TArray<Integer>;
  huff_b35_xlat: TArray<Integer>;
  huff_b37_cb: TArray<Integer>;
  huff_b37_xlat: TArray<Integer>;
  huff_b41_cb: TArray<Integer>;
  huff_b41_xlat: TArray<Integer>;
  huff_b42_cb: TArray<Integer>;
  huff_b42_xlat: TArray<Integer>;
  huff_b43_cb: TArray<Integer>;
  huff_b43_xlat: TArray<Integer>;
  huff_b47_cb: TArray<Integer>;
  huff_b47_xlat: TArray<Integer>;
  huff_b52_cb: TArray<Integer>;
  huff_b52_xlat: TArray<Integer>;
  huff_b53_cb: TArray<Integer>;
  huff_b53_xlat: TArray<Integer>;
  huff_b56_cb: TArray<Integer>;
  huff_b56_xlat: TArray<Integer>;
  huff_b62_cb: TArray<Integer>;
  huff_b62_xlat: TArray<Integer>;
  huff_b63_cb: TArray<Integer>;
  huff_b63_xlat: TArray<Integer>;
  huff_b64_cb: TArray<Integer>;
  huff_b64_xlat: TArray<Integer>;
  huff_b65_cb: TArray<Integer>;
  huff_b65_xlat: TArray<Integer>;
  huff_b66_cb: TArray<Integer>;
  huff_b66_xlat: TArray<Integer>;
  huff_b67_cb: TArray<Integer>;
  huff_b67_xlat: TArray<Integer>;
  huff_b71_cb: TArray<Integer>;
  huff_b71_xlat: TArray<Integer>;
  huff_b73_cb: TArray<Integer>;
  huff_b73_xlat: TArray<Integer>;
  huff_b74_cb: TArray<Integer>;
  huff_b74_xlat: TArray<Integer>;
  huff_b75_cb: TArray<Integer>;
  huff_b75_xlat: TArray<Integer>;
  huff_b77_cb: TArray<Integer>;
  huff_b77_xlat: TArray<Integer>;
  atrac3p_spectra_tabs: TArray<TATSpecCodeTab>;
  atrac3p_wl_huff_code1: TArray<Integer>;
  atrac3p_wl_huff_bits1: TArray<Integer>;
  atrac3p_wl_huff_xlat1: TArray<Integer>;
  atrac3p_wl_huff_code2: TArray<Integer>;
  atrac3p_wl_huff_bits2: TArray<Integer>;
  atrac3p_wl_huff_xlat2: TArray<Integer>;
  atrac3p_wl_huff_code3: TArray<Integer>;
  atrac3p_wl_huff_bits3: TArray<Integer>;
  atrac3p_wl_huff_code4: TArray<Integer>;
  atrac3p_wl_huff_bits4: TArray<Integer>;
  atrac3p_sf_huff_code1: TArray<Integer>;
  atrac3p_sf_huff_bits1: TArray<Integer>;
  atrac3p_sf_huff_xlat1: TArray<Integer>;
  atrac3p_sf_huff_xlat2: TArray<Integer>;
  atrac3p_sf_huff_code2: TArray<Integer>;
  atrac3p_sf_huff_bits2: TArray<Integer>;
  atrac3p_sf_huff_code3: TArray<Integer>;
  atrac3p_sf_huff_bits3: TArray<Integer>;
  atrac3p_sf_huff_code4: TArray<Integer>;
  atrac3p_sf_huff_bits4: TArray<Integer>;
  atrac3p_sf_huff_xlat4: TArray<Integer>;
  atrac3p_sf_huff_xlat5: TArray<Integer>;
  atrac3p_sf_huff_code5: TArray<Integer>;
  atrac3p_sf_huff_bits5: TArray<Integer>;
  atrac3p_sf_huff_code6: TArray<Integer>;
  atrac3p_sf_huff_bits6: TArray<Integer>;
  atrac3p_ct_huff_code1: TArray<Integer>;
  atrac3p_ct_huff_bits1: TArray<Integer>;
  atrac3p_ct_huff_code2: TArray<Integer>;
  atrac3p_ct_huff_bits2: TArray<Integer>;
  atrac3p_ct_huff_xlat1: TArray<Integer>;
  atrac3p_ct_huff_code3: TArray<Integer>;
  atrac3p_ct_huff_bits3: TArray<Integer>;
  atrac3p_wl_weights: TArray<TArray<Integer>>;
  atrac3p_sf_weights: TArray<TArray<Integer>>;
  atrac3p_qu_num_to_seg: TArray<Integer>;
  atrac3p_qu_to_subband: TArray<Integer>;
  atrac3p_subband_to_num_powgrps: TArray<Integer>;
  atrac3p_wl_shapes: TArray<TArray<TArray<Integer>>>;
  atrac3p_sf_shapes: TArray<TArray<Integer>>;
  atrac3p_ct_restricted_to_full: TArray<TArray<TArray<Integer>>>;
  atrac3p_huff_gain_npoints1_cb: TArray<Integer>;
  atrac3p_huff_gain_npoints2_xlat: TArray<Integer>;
  atrac3p_huff_gain_lev1_cb: TArray<Integer>;
  atrac3p_huff_gain_lev1_xlat: TArray<Integer>;
  atrac3p_huff_gain_lev2_cb: TArray<Integer>;
  atrac3p_huff_gain_lev2_xlat: TArray<Integer>;
  atrac3p_huff_gain_lev3_cb: TArray<Integer>;
  atrac3p_huff_gain_lev3_xlat: TArray<Integer>;
  atrac3p_huff_gain_lev4_cb: TArray<Integer>;
  atrac3p_huff_gain_lev4_xlat: TArray<Integer>;
  atrac3p_huff_gain_loc1_cb: TArray<Integer>;
  atrac3p_huff_gain_loc1_xlat: TArray<Integer>;
  atrac3p_huff_gain_loc2_cb: TArray<Integer>;
  atrac3p_huff_gain_loc2_xlat: TArray<Integer>;
  atrac3p_huff_gain_loc3_cb: TArray<Integer>;
  atrac3p_huff_gain_loc3_xlat: TArray<Integer>;
  atrac3p_huff_gain_loc4_cb: TArray<Integer>;
  atrac3p_huff_gain_loc4_xlat: TArray<Integer>;
  atrac3p_huff_gain_loc5_cb: TArray<Integer>;
  atrac3p_huff_gain_loc5_xlat: TArray<Integer>;
  atrac3p_huff_tonebands_cb: TArray<Integer>;
  atrac3p_huff_numwavs1_cb: TArray<Integer>;
  atrac3p_huff_numwavs2_cb: TArray<Integer>;
  atrac3p_huff_numwavs2_xlat: TArray<Integer>;
  atrac3p_huff_wav_ampsf1_cb: TArray<Integer>;
  atrac3p_huff_wav_ampsf1_xlat: TArray<Integer>;
  atrac3p_huff_wav_ampsf2_cb: TArray<Integer>;
  atrac3p_huff_wav_ampsf2_xlat: TArray<Integer>;
  atrac3p_huff_wav_ampsf3_cb: TArray<Integer>;
  atrac3p_huff_wav_ampsf3_xlat: TArray<Integer>;
  atrac3p_huff_freq_cb: TArray<Integer>;
  atrac3p_huff_freq_xlat: TArray<Integer>;

implementation

class function TATSpecCodeTab.Create(GroupSize, NumCoeffs, Bits, IsSigned, Redirect: Integer; const CB, Xlat: TArray<Integer>): TATSpecCodeTab;
begin
  Result.GroupSize := GroupSize;
  Result.NumCoeffs := NumCoeffs;
  Result.Bits := Bits;
  Result.IsSigned := IsSigned <> 0;
  Result.Redirect := Redirect;
  Result.CB := CB;
  Result.Xlat := Xlat;
end;

// Static integer data avoids thousands of generated element assignments and
// managed temporaries in the compiler's unit initialization routine.
function CopyIntegerTable(const Values: array of Integer): TArray<Integer>;
begin
  SetLength(Result, Length(Values));
  if Length(Values) > 0 then
    Move(Values[0], Result[0], Length(Values) * SizeOf(Integer));
end;

procedure Init_huff_a01_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 1, 7, 0, 19, 5, 13, 21, 6, 8);
begin
  huff_a01_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a01_xlat;
const
  Values: array[0..80] of Integer = (
    0, 3, 64, 192, 16, 48, 4, 12, 1, 80, 208, 112, 240, 196, 20, 52, 76, 28, 60, 65, 193, 49, 5, 13,
    195, 19, 7, 15, 68, 204, 17, 67, 51, 84, 116, 220, 252, 113, 21, 77, 205, 29, 211, 199, 55, 63,
    212, 244, 92, 124, 81, 209, 241, 69, 197, 53, 221, 61, 83, 115, 243, 71, 23, 119, 79, 207, 31,
    85, 245, 125, 215, 95, 255, 213, 117, 93, 253, 87, 247, 223, 127);
begin
  huff_a01_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a02_cb;
const
  Values: array[0..12] of Integer = (
    2, 12, 1, 0, 4, 11, 0, 1, 29, 6, 20, 7, 2);
begin
  huff_a02_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a02_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 16, 4, 1, 80, 68, 20, 84, 65, 17, 81, 5, 69, 21, 85, 144, 128, 32, 96, 132, 148, 36, 100,
    8, 72, 24, 88, 129, 145, 33, 133, 149, 101, 9, 73, 25, 89, 2, 66, 18, 82, 6, 70, 22, 86, 136,
    97, 37, 41, 105, 90, 160, 164, 152, 40, 104, 161, 165, 137, 153, 169, 130, 146, 34, 98, 150, 38,
    102, 10, 74, 26, 168, 134, 166, 138, 154, 42, 106, 162, 170);
begin
  huff_a02_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a03_cb;
const
  Values: array[0..8] of Integer = (
    3, 9, 1, 8, 0, 13, 18, 7, 2);
begin
  huff_a03_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a03_xlat;
const
  Values: array[0..48] of Integer = (
    0, 8, 56, 1, 9, 57, 7, 15, 63, 16, 48, 17, 49, 2, 10, 58, 5, 6, 14, 62, 23, 55, 24, 40, 25, 41,
    42, 50, 3, 11, 51, 59, 13, 21, 61, 22, 30, 54, 31, 47, 18, 26, 19, 43, 29, 53, 46, 27, 45);
begin
  huff_a03_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a04_cb;
const
  Values: array[0..3] of Integer = (
    2, 3, 2, 4);
begin
  huff_a04_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a04_xlat;
const
  Values: array[0..5] of Integer = (
    1, 2, 0, 3, 4, 5);
begin
  huff_a04_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a05_cb;
const
  Values: array[0..11] of Integer = (
    3, 12, 1, 3, 5, 8, 12, 23, 72, 68, 31, 2);
begin
  huff_a05_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a05_xlat;
const
  Values: array[0..224] of Integer = (
    0, 16, 240, 1, 17, 241, 15, 31, 255, 32, 224, 225, 2, 242, 14, 30, 47, 48, 208, 33, 18, 34, 226,
    3, 13, 46, 238, 254, 239, 64, 192, 49, 193, 209, 50, 210, 19, 35, 227, 243, 4, 244, 12, 28, 29,
    45, 237, 253, 62, 222, 63, 223, 80, 96, 112, 144, 160, 176, 65, 81, 97, 113, 145, 161, 177, 66,
    98, 146, 162, 194, 51, 195, 211, 20, 36, 52, 212, 228, 5, 21, 245, 6, 22, 38, 230, 246, 7, 23,
    231, 247, 9, 25, 41, 249, 10, 26, 42, 234, 250, 11, 27, 251, 44, 60, 220, 236, 252, 61, 77, 205,
    221, 78, 110, 126, 174, 206, 79, 95, 111, 127, 159, 175, 191, 207, 82, 114, 178, 67, 83, 99,
    115, 147, 163, 179, 68, 100, 116, 148, 164, 180, 196, 37, 53, 165, 197, 213, 229, 54, 70, 182,
    198, 214, 39, 55, 71, 183, 199, 215, 57, 73, 89, 201, 217, 233, 58, 74, 90, 202, 218, 43, 59,
    75, 107, 123, 219, 235, 76, 92, 108, 124, 156, 172, 204, 93, 109, 125, 157, 173, 189, 94, 158,
    190, 84, 69, 85, 101, 117, 149, 181, 86, 102, 118, 150, 166, 87, 103, 151, 167, 105, 121, 169,
    185, 106, 122, 154, 170, 186, 91, 155, 171, 187, 203, 188, 119, 153);
begin
  huff_a05_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a06_cb;
const
  Values: array[0..6] of Integer = (
    2, 6, 1, 3, 2, 6, 4);
begin
  huff_a06_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a06_xlat;
const
  Values: array[0..15] of Integer = (
    1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 10, 11, 12, 15);
begin
  huff_a06_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a07_cb;
const
  Values: array[0..10] of Integer = (
    2, 10, 1, 2, 2, 2, 6, 14, 21, 13, 2);
begin
  huff_a07_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a07_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 63, 2, 62, 3, 61, 4, 5, 6, 58, 59, 60, 7, 8, 9, 10, 26, 27, 28, 36, 37, 38, 54, 55, 56,
    57, 11, 12, 13, 14, 15, 16, 25, 29, 30, 31, 33, 34, 35, 39, 47, 48, 49, 50, 51, 52, 53, 17, 18,
    19, 20, 21, 22, 23, 41, 42, 43, 44, 45, 46, 24, 40);
begin
  huff_a07_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a11_cb;
const
  Values: array[0..12] of Integer = (
    1, 11, 1, 0, 0, 0, 8, 1, 18, 9, 22, 10, 12);
begin
  huff_a11_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a11_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 192, 16, 48, 4, 12, 1, 3, 208, 80, 112, 240, 196, 52, 76, 204, 28, 65, 193, 49, 5, 13,
    67, 195, 19, 7, 15, 68, 20, 116, 220, 60, 17, 29, 51, 55, 84, 212, 244, 92, 124, 252, 209, 113,
    241, 21, 53, 77, 205, 221, 61, 211, 115, 71, 199, 23, 119, 63, 81, 69, 197, 85, 83, 243, 79,
    207, 31, 255, 213, 117, 245, 93, 125, 253, 87, 215, 247, 95, 223, 127);
begin
  huff_a11_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a12_cb;
const
  Values: array[0..7] of Integer = (
    5, 10, 16, 11, 32, 19, 1, 2);
begin
  huff_a12_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a12_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 16, 80, 4, 68, 20, 84, 1, 65, 17, 81, 5, 69, 21, 85, 144, 148, 88, 145, 149, 25, 89, 6,
    70, 22, 86, 128, 96, 132, 36, 100, 164, 8, 72, 24, 104, 129, 33, 97, 161, 133, 37, 101, 165, 9,
    73, 153, 105, 169, 2, 66, 18, 82, 150, 38, 102, 26, 90, 32, 160, 136, 152, 40, 168, 137, 41,
    130, 146, 34, 98, 134, 166, 10, 74, 154, 106, 170, 162, 138, 42);
begin
  huff_a12_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a13_cb;
const
  Values: array[0..11] of Integer = (
    1, 10, 1, 0, 0, 4, 2, 2, 9, 15, 12, 4);
begin
  huff_a13_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a13_xlat;
const
  Values: array[0..48] of Integer = (
    0, 8, 56, 1, 7, 57, 15, 9, 63, 16, 48, 49, 2, 58, 6, 14, 62, 23, 24, 40, 17, 41, 10, 50, 3, 11,
    59, 5, 13, 61, 22, 31, 55, 25, 18, 26, 42, 19, 51, 21, 53, 30, 46, 54, 47, 27, 43, 29, 45);
begin
  huff_a13_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a14_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 4, 3, 5, 16, 28, 34, 26, 4);
begin
  huff_a14_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a14_xlat;
const
  Values: array[0..120] of Integer = (
    0, 16, 240, 1, 15, 241, 31, 255, 32, 224, 17, 2, 14, 48, 80, 176, 208, 33, 225, 18, 242, 3, 5,
    11, 13, 30, 254, 47, 239, 64, 192, 49, 81, 177, 193, 209, 34, 82, 226, 19, 243, 4, 21, 245, 27,
    235, 251, 12, 29, 253, 46, 94, 238, 63, 95, 191, 223, 65, 50, 66, 178, 210, 35, 83, 179, 227,
    20, 36, 228, 244, 37, 53, 213, 229, 43, 59, 219, 28, 44, 188, 236, 252, 45, 189, 237, 62, 78,
    190, 222, 79, 207, 194, 51, 67, 195, 211, 52, 68, 84, 180, 212, 69, 85, 197, 75, 203, 60, 76,
    92, 204, 220, 61, 77, 93, 205, 221, 206, 196, 181, 91, 187);
begin
  huff_a14_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a15_cb;
const
  Values: array[0..8] of Integer = (
    5, 11, 9, 12, 16, 44, 98, 42, 4);
begin
  huff_a15_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a15_xlat;
const
  Values: array[0..224] of Integer = (
    0, 16, 240, 1, 17, 241, 15, 31, 255, 32, 224, 33, 225, 2, 18, 242, 14, 30, 254, 47, 239, 48,
    208, 49, 209, 34, 226, 3, 19, 243, 13, 29, 253, 46, 238, 63, 223, 64, 96, 112, 144, 160, 192,
    65, 193, 50, 66, 194, 210, 35, 51, 211, 227, 4, 20, 36, 228, 244, 6, 22, 246, 7, 9, 10, 26, 250,
    12, 28, 44, 236, 252, 45, 61, 221, 237, 62, 78, 206, 222, 79, 207, 80, 176, 81, 97, 113, 145,
    161, 177, 82, 98, 114, 146, 162, 178, 67, 83, 99, 115, 147, 163, 195, 52, 68, 100, 164, 196,
    212, 5, 21, 37, 53, 213, 229, 245, 38, 54, 70, 198, 214, 230, 23, 39, 55, 199, 215, 231, 247,
    25, 41, 57, 201, 217, 233, 249, 42, 58, 74, 90, 202, 218, 234, 11, 27, 43, 59, 203, 219, 235,
    251, 60, 76, 108, 124, 156, 172, 188, 204, 220, 77, 93, 109, 125, 157, 173, 189, 205, 94, 110,
    126, 158, 174, 190, 95, 111, 127, 159, 175, 191, 179, 84, 116, 148, 180, 69, 85, 101, 117, 149,
    165, 181, 197, 86, 102, 118, 150, 166, 182, 71, 87, 103, 167, 183, 73, 89, 105, 169, 185, 106,
    122, 154, 170, 186, 75, 91, 107, 123, 155, 171, 187, 92, 119, 151, 121, 153);
begin
  huff_a15_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a16_cb;
const
  Values: array[0..12] of Integer = (
    2, 12, 1, 1, 2, 2, 5, 7, 21, 54, 85, 62, 16);
begin
  huff_a16_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a16_xlat;
const
  Values: array[0..255] of Integer = (
    0, 1, 16, 17, 33, 18, 32, 49, 2, 34, 19, 48, 65, 50, 3, 35, 20, 36, 64, 81, 97, 209, 225, 66,
    82, 210, 51, 67, 211, 4, 52, 5, 21, 37, 22, 29, 45, 30, 46, 80, 96, 208, 224, 240, 113, 129,
    241, 98, 114, 226, 242, 83, 99, 227, 243, 68, 84, 212, 228, 244, 53, 69, 85, 213, 229, 245, 6,
    38, 54, 214, 7, 23, 39, 55, 215, 24, 40, 28, 13, 61, 77, 93, 109, 141, 14, 62, 78, 94, 15, 31,
    47, 63, 95, 112, 128, 144, 192, 145, 161, 177, 193, 130, 146, 162, 194, 115, 131, 147, 163, 195,
    100, 116, 132, 148, 164, 196, 101, 117, 133, 70, 86, 102, 198, 230, 246, 71, 87, 231, 247, 8,
    56, 72, 88, 104, 216, 232, 248, 9, 25, 41, 57, 89, 217, 233, 249, 26, 42, 58, 218, 234, 250, 27,
    43, 219, 235, 251, 12, 44, 60, 220, 236, 125, 157, 173, 189, 205, 110, 126, 142, 158, 174, 190,
    206, 79, 111, 127, 143, 175, 160, 178, 179, 180, 149, 165, 181, 197, 118, 134, 150, 166, 182,
    103, 119, 135, 151, 199, 120, 136, 152, 200, 73, 105, 121, 137, 153, 201, 10, 74, 90, 106, 122,
    202, 11, 59, 75, 91, 107, 203, 76, 92, 108, 124, 140, 156, 172, 188, 204, 252, 221, 237, 253,
    222, 238, 254, 159, 191, 207, 223, 239, 255, 176, 167, 183, 168, 184, 169, 185, 138, 154, 170,
    186, 123, 139, 155, 171, 187);
begin
  huff_a16_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a17_cb;
const
  Values: array[0..8] of Integer = (
    3, 9, 3, 2, 5, 7, 17, 23, 6);
begin
  huff_a17_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a17_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 63, 2, 62, 3, 4, 59, 60, 61, 5, 6, 7, 8, 56, 57, 58, 9, 10, 11, 12, 13, 14, 26, 27, 36,
    37, 38, 50, 51, 52, 53, 54, 55, 15, 16, 17, 18, 19, 20, 21, 25, 28, 29, 30, 31, 33, 34, 35, 39,
    43, 44, 45, 46, 47, 48, 49, 22, 23, 24, 40, 41, 42);
begin
  huff_a17_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a21_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 2, 6, 0, 7, 21, 15, 17, 8, 4);
begin
  huff_a21_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a21_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 192, 16, 48, 4, 12, 1, 3, 208, 112, 52, 28, 13, 19, 7, 80, 240, 68, 196, 20, 116, 76,
    204, 220, 60, 65, 193, 17, 49, 5, 29, 67, 195, 51, 55, 15, 84, 244, 252, 209, 113, 21, 77, 205,
    221, 211, 115, 71, 199, 119, 63, 212, 92, 124, 81, 241, 69, 197, 85, 53, 61, 83, 243, 23, 79,
    207, 31, 255, 117, 245, 93, 125, 215, 247, 95, 223, 213, 253, 87, 127);
begin
  huff_a21_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a22_cb;
const
  Values: array[0..9] of Integer = (
    2, 9, 1, 4, 0, 4, 3, 8, 3, 2);
begin
  huff_a22_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a22_xlat;
const
  Values: array[0..24] of Integer = (
    0, 8, 56, 1, 7, 9, 57, 15, 63, 16, 2, 6, 48, 17, 49, 10, 58, 14, 23, 55, 50, 22, 62, 18, 54);
begin
  huff_a22_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a23_cb;
const
  Values: array[0..8] of Integer = (
    3, 9, 5, 0, 4, 6, 10, 16, 8);
begin
  huff_a23_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a23_xlat;
const
  Values: array[0..48] of Integer = (
    0, 8, 56, 1, 7, 9, 57, 15, 63, 16, 48, 2, 58, 6, 14, 24, 40, 17, 49, 10, 3, 5, 62, 23, 55, 25,
    41, 18, 42, 50, 11, 51, 59, 13, 21, 61, 22, 30, 54, 31, 47, 26, 19, 27, 43, 29, 45, 53, 46);
begin
  huff_a23_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a24_cb;
const
  Values: array[0..4] of Integer = (
    2, 4, 3, 1, 2);
begin
  huff_a24_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a25_cb;
const
  Values: array[0..4] of Integer = (
    2, 4, 1, 5, 2);
begin
  huff_a25_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a25_xlat;
const
  Values: array[0..7] of Integer = (
    1, 0, 2, 3, 4, 5, 6, 7);
begin
  huff_a25_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a26_cb;
const
  Values: array[0..9] of Integer = (
    4, 11, 3, 4, 12, 15, 34, 83, 75, 30);
begin
  huff_a26_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a26_xlat;
const
  Values: array[0..255] of Integer = (
    0, 1, 17, 16, 33, 18, 34, 32, 48, 49, 65, 2, 50, 3, 19, 35, 51, 20, 36, 64, 81, 97, 66, 82, 67,
    83, 4, 52, 68, 21, 37, 53, 22, 38, 80, 96, 113, 129, 209, 98, 114, 130, 210, 99, 115, 211, 84,
    100, 5, 69, 85, 101, 6, 54, 70, 86, 23, 39, 55, 71, 24, 40, 56, 25, 29, 45, 61, 30, 112, 128,
    144, 208, 224, 145, 161, 177, 193, 225, 241, 146, 162, 194, 226, 242, 131, 147, 163, 195, 227,
    243, 116, 132, 148, 164, 196, 212, 228, 244, 117, 133, 149, 213, 229, 102, 118, 134, 214, 230,
    7, 87, 103, 119, 215, 8, 72, 88, 104, 216, 9, 41, 57, 73, 89, 105, 26, 42, 58, 74, 27, 43, 28,
    44, 60, 76, 13, 77, 93, 109, 125, 141, 14, 46, 62, 78, 94, 110, 31, 47, 63, 79, 95, 160, 176,
    192, 240, 178, 179, 180, 165, 181, 197, 245, 150, 166, 182, 198, 246, 135, 151, 167, 183, 199,
    231, 247, 120, 136, 152, 168, 200, 232, 248, 121, 137, 153, 201, 217, 233, 249, 10, 90, 106,
    122, 138, 218, 234, 250, 11, 59, 75, 91, 107, 123, 139, 219, 12, 92, 108, 124, 140, 156, 220,
    157, 173, 189, 205, 126, 142, 158, 174, 190, 15, 111, 127, 143, 159, 175, 184, 169, 185, 154,
    170, 186, 202, 155, 171, 187, 203, 235, 251, 172, 188, 204, 236, 252, 221, 237, 253, 206, 222,
    238, 254, 191, 207, 223, 239, 255);
begin
  huff_a26_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a27_cb;
const
  Values: array[0..6] of Integer = (
    4, 8, 3, 14, 10, 20, 16);
begin
  huff_a27_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a27_xlat;
const
  Values: array[0..62] of Integer = (
    0, 2, 3, 1, 5, 6, 7, 9, 54, 55, 56, 58, 59, 60, 61, 62, 63, 4, 8, 10, 11, 12, 14, 49, 52, 53,
    57, 13, 15, 16, 17, 18, 19, 22, 23, 25, 26, 30, 39, 43, 44, 45, 46, 47, 48, 50, 51, 20, 21, 24,
    27, 28, 29, 31, 33, 34, 35, 36, 37, 38, 40, 41, 42);
begin
  huff_a27_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a31_cb;
const
  Values: array[0..7] of Integer = (
    1, 6, 1, 0, 3, 1, 0, 4);
begin
  huff_a31_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a31_xlat;
const
  Values: array[0..8] of Integer = (
    0, 4, 12, 1, 3, 5, 13, 7, 15);
begin
  huff_a31_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a32_cb;
const
  Values: array[0..12] of Integer = (
    1, 11, 1, 0, 0, 2, 2, 6, 12, 18, 19, 15, 6);
begin
  huff_a32_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a32_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 1, 16, 4, 128, 80, 32, 20, 5, 2, 144, 96, 68, 84, 36, 8, 24, 65, 17, 21, 9, 6, 160, 132,
    148, 100, 164, 72, 88, 40, 81, 33, 69, 85, 37, 25, 18, 22, 10, 26, 104, 168, 129, 145, 97, 161,
    133, 149, 101, 165, 73, 89, 41, 105, 66, 82, 70, 86, 42, 136, 152, 137, 153, 169, 130, 146, 34,
    98, 134, 38, 102, 74, 90, 106, 162, 150, 166, 138, 154, 170);
begin
  huff_a32_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a33_cb;
const
  Values: array[0..11] of Integer = (
    3, 12, 1, 1, 13, 1, 14, 28, 33, 81, 32, 52);
begin
  huff_a33_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a33_xlat;
const
  Values: array[0..255] of Integer = (
    0, 16, 64, 80, 4, 68, 20, 84, 1, 65, 17, 81, 5, 69, 21, 85, 144, 32, 148, 100, 24, 33, 149, 25,
    105, 2, 82, 6, 70, 22, 128, 96, 132, 212, 36, 8, 72, 88, 104, 129, 145, 97, 133, 37, 101, 165,
    9, 73, 89, 41, 66, 18, 86, 150, 166, 10, 23, 27, 208, 196, 116, 244, 136, 200, 40, 161, 113,
    197, 213, 117, 153, 185, 77, 29, 45, 109, 34, 98, 102, 74, 26, 154, 106, 142, 94, 67, 35, 7, 71,
    87, 107, 192, 160, 224, 112, 176, 164, 228, 52, 180, 152, 216, 168, 56, 120, 12, 76, 28, 92,
    156, 108, 124, 193, 209, 225, 49, 229, 53, 181, 245, 137, 169, 121, 249, 13, 205, 157, 221, 173,
    61, 125, 130, 194, 146, 210, 226, 114, 242, 134, 214, 230, 118, 182, 138, 90, 218, 234, 250, 78,
    30, 158, 238, 3, 19, 83, 151, 183, 11, 75, 139, 91, 155, 235, 123, 15, 79, 31, 95, 159, 47, 63,
    191, 232, 184, 248, 140, 44, 60, 252, 177, 201, 217, 233, 57, 93, 237, 189, 162, 50, 38, 54, 42,
    170, 186, 14, 46, 110, 131, 195, 147, 99, 179, 167, 55, 48, 240, 204, 220, 172, 236, 188, 241,
    141, 253, 178, 198, 246, 202, 58, 122, 206, 222, 174, 62, 126, 190, 254, 211, 163, 227, 51, 115,
    243, 135, 199, 215, 39, 103, 231, 119, 247, 203, 219, 43, 171, 59, 187, 251, 143, 207, 223, 111,
    175, 239, 127, 255);
begin
  huff_a33_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a34_cb;
const
  Values: array[0..6] of Integer = (
    1, 5, 1, 1, 1, 1, 2);
begin
  huff_a34_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a34_xlat;
const
  Values: array[0..5] of Integer = (
    1, 0, 2, 3, 4, 5);
begin
  huff_a34_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a35_cb;
const
  Values: array[0..10] of Integer = (
    2, 10, 1, 0, 2, 3, 6, 19, 9, 75, 110);
begin
  huff_a35_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a35_xlat;
const
  Values: array[0..224] of Integer = (
    0, 240, 15, 16, 1, 255, 32, 224, 17, 241, 14, 31, 48, 64, 208, 33, 225, 2, 18, 34, 226, 242, 3,
    19, 30, 46, 62, 238, 254, 47, 239, 210, 67, 243, 4, 13, 45, 61, 63, 223, 80, 96, 112, 144, 176,
    49, 65, 145, 161, 193, 209, 66, 162, 194, 35, 51, 227, 36, 52, 180, 212, 244, 5, 21, 69, 229,
    22, 54, 86, 166, 198, 214, 246, 87, 199, 247, 9, 41, 73, 89, 105, 249, 10, 42, 58, 74, 218, 234,
    250, 11, 43, 171, 235, 251, 12, 28, 44, 60, 76, 92, 204, 220, 252, 29, 77, 109, 189, 205, 237,
    253, 78, 110, 206, 222, 127, 160, 192, 81, 97, 113, 177, 50, 82, 98, 114, 146, 178, 83, 99, 115,
    147, 163, 179, 195, 211, 20, 68, 84, 100, 116, 148, 164, 196, 228, 37, 53, 85, 101, 117, 149,
    165, 181, 197, 213, 245, 6, 38, 70, 102, 118, 150, 182, 230, 7, 23, 39, 55, 71, 103, 119, 151,
    167, 183, 215, 231, 25, 57, 121, 153, 169, 185, 201, 217, 233, 26, 90, 106, 122, 154, 170, 186,
    202, 27, 59, 75, 91, 107, 123, 155, 187, 203, 219, 108, 124, 156, 172, 188, 236, 93, 125, 157,
    173, 221, 94, 126, 158, 174, 190, 79, 95, 111, 159, 175, 191, 207);
begin
  huff_a35_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a36_cb;
const
  Values: array[0..11] of Integer = (
    3, 12, 1, 3, 5, 5, 13, 27, 69, 96, 35, 2);
begin
  huff_a36_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a36_xlat;
const
  Values: array[0..255] of Integer = (
    0, 16, 1, 17, 32, 33, 2, 18, 34, 49, 65, 50, 19, 35, 48, 64, 81, 66, 3, 51, 67, 4, 20, 36, 52,
    21, 37, 80, 97, 113, 209, 82, 98, 114, 210, 83, 99, 211, 68, 84, 100, 5, 53, 69, 85, 22, 38, 54,
    70, 23, 39, 29, 45, 61, 96, 112, 208, 129, 145, 161, 193, 225, 241, 130, 146, 194, 226, 242,
    115, 131, 227, 243, 116, 132, 196, 212, 228, 244, 101, 117, 133, 213, 229, 6, 86, 102, 214, 230,
    7, 55, 71, 87, 103, 215, 231, 24, 40, 56, 72, 88, 216, 25, 41, 42, 28, 44, 13, 77, 93, 109, 125,
    141, 157, 30, 46, 62, 78, 94, 110, 126, 31, 47, 63, 128, 144, 160, 192, 224, 240, 177, 162, 178,
    147, 163, 179, 195, 148, 164, 180, 149, 165, 181, 197, 245, 118, 134, 150, 166, 198, 246, 119,
    135, 151, 167, 199, 247, 8, 104, 120, 136, 152, 200, 232, 248, 9, 57, 73, 89, 105, 121, 137,
    217, 233, 249, 10, 26, 58, 74, 90, 106, 218, 234, 250, 27, 43, 59, 75, 91, 219, 235, 251, 12,
    60, 76, 92, 108, 124, 140, 156, 220, 236, 173, 189, 205, 221, 237, 14, 142, 158, 174, 190, 15,
    79, 95, 111, 127, 143, 159, 175, 176, 182, 183, 168, 184, 153, 169, 185, 201, 122, 138, 154,
    170, 186, 202, 11, 107, 123, 139, 155, 203, 172, 188, 204, 252, 253, 206, 222, 238, 254, 191,
    207, 223, 239, 255, 171, 187);
begin
  huff_a36_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a37_cb;
const
  Values: array[0..6] of Integer = (
    4, 8, 7, 6, 8, 22, 20);
begin
  huff_a37_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a37_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 2, 3, 61, 62, 63, 4, 5, 6, 58, 59, 60, 7, 8, 9, 10, 54, 55, 56, 57, 11, 12, 13, 14, 15,
    16, 25, 26, 27, 28, 29, 30, 35, 36, 37, 38, 48, 49, 50, 51, 52, 53, 17, 18, 19, 20, 21, 22, 23,
    24, 31, 33, 34, 39, 40, 41, 42, 43, 44, 45, 46, 47);
begin
  huff_a37_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a41_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 6, 2, 0, 0, 0, 19, 9, 24, 20);
begin
  huff_a41_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a41_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 192, 16, 48, 4, 12, 1, 3, 80, 208, 112, 240, 196, 52, 76, 204, 28, 65, 193, 49, 5, 13,
    67, 195, 19, 7, 15, 68, 20, 116, 220, 60, 17, 29, 51, 55, 84, 212, 244, 92, 124, 252, 209, 113,
    241, 197, 21, 53, 77, 205, 221, 61, 211, 115, 71, 199, 23, 119, 31, 63, 81, 69, 85, 213, 117,
    245, 93, 125, 253, 83, 243, 87, 215, 247, 79, 207, 95, 223, 127, 255);
begin
  huff_a41_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a42_cb;
const
  Values: array[0..9] of Integer = (
    3, 10, 1, 2, 13, 1, 31, 13, 16, 4);
begin
  huff_a42_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a42_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 1, 16, 80, 4, 68, 20, 84, 65, 17, 81, 5, 69, 21, 85, 89, 128, 144, 32, 96, 132, 148, 36,
    100, 8, 72, 24, 88, 129, 145, 33, 97, 133, 149, 37, 101, 9, 73, 25, 2, 66, 18, 82, 6, 70, 22,
    86, 160, 164, 104, 161, 165, 153, 41, 105, 150, 102, 74, 26, 90, 136, 152, 40, 137, 169, 130,
    146, 34, 98, 134, 38, 166, 10, 154, 42, 106, 168, 162, 138, 170);
begin
  huff_a42_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a43_cb;
const
  Values: array[0..4] of Integer = (
    2, 4, 2, 3, 2);
begin
  huff_a43_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a43_xlat;
const
  Values: array[0..6] of Integer = (
    0, 7, 1, 2, 6, 3, 5);
begin
  huff_a43_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a44_cb;
const
  Values: array[0..8] of Integer = (
    4, 10, 5, 4, 12, 17, 47, 24, 12);
begin
  huff_a44_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a44_xlat;
const
  Values: array[0..120] of Integer = (
    0, 16, 240, 1, 15, 17, 241, 31, 255, 32, 224, 33, 225, 2, 18, 242, 14, 30, 254, 47, 239, 48, 80,
    208, 209, 34, 226, 3, 19, 243, 13, 29, 45, 253, 46, 238, 63, 223, 64, 176, 192, 49, 65, 81, 177,
    193, 50, 178, 194, 210, 35, 179, 211, 227, 4, 20, 228, 244, 5, 21, 213, 229, 245, 11, 27, 43,
    59, 235, 251, 12, 28, 44, 252, 61, 93, 237, 62, 78, 94, 190, 222, 79, 95, 191, 207, 66, 82, 51,
    83, 195, 36, 180, 212, 37, 53, 197, 75, 203, 219, 60, 76, 92, 220, 236, 77, 189, 205, 221, 206,
    67, 52, 68, 84, 196, 69, 85, 181, 91, 187, 188, 204);
begin
  huff_a44_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a45_cb;
const
  Values: array[0..4] of Integer = (
    2, 4, 2, 2, 4);
begin
  huff_a45_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a45_xlat;
const
  Values: array[0..7] of Integer = (
    1, 2, 0, 3, 4, 5, 6, 7);
begin
  huff_a45_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a46_cb;
const
  Values: array[0..6] of Integer = (
    5, 9, 1, 16, 31, 36, 172);
begin
  huff_a46_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a46_xlat;
const
  Values: array[0..255] of Integer = (
    2, 0, 48, 33, 49, 65, 97, 18, 34, 66, 98, 67, 83, 36, 69, 38, 39, 16, 64, 176, 1, 17, 129, 50,
    82, 114, 146, 3, 19, 51, 99, 20, 52, 84, 100, 116, 5, 21, 37, 53, 85, 101, 6, 70, 86, 87, 103,
    136, 32, 81, 145, 209, 242, 35, 131, 147, 4, 68, 132, 148, 117, 133, 197, 54, 102, 150, 182, 7,
    55, 151, 8, 40, 56, 72, 104, 9, 105, 121, 10, 42, 27, 155, 44, 77, 80, 96, 112, 128, 144, 160,
    192, 208, 224, 240, 113, 161, 177, 193, 225, 241, 130, 162, 178, 194, 210, 226, 115, 163, 179,
    195, 211, 227, 243, 164, 180, 196, 212, 228, 244, 149, 165, 181, 213, 229, 245, 22, 118, 134,
    166, 198, 214, 230, 246, 23, 71, 119, 135, 167, 183, 199, 215, 231, 247, 24, 88, 120, 152, 168,
    184, 200, 216, 232, 248, 25, 41, 57, 73, 89, 137, 153, 169, 185, 201, 217, 233, 249, 26, 58, 74,
    90, 106, 122, 138, 154, 170, 186, 202, 218, 234, 250, 11, 43, 59, 75, 91, 107, 123, 139, 171,
    187, 203, 219, 235, 251, 12, 28, 60, 76, 92, 108, 124, 140, 156, 172, 188, 204, 220, 236, 252,
    13, 29, 45, 61, 93, 109, 125, 141, 157, 173, 189, 205, 221, 237, 253, 14, 30, 46, 62, 78, 94,
    110, 126, 142, 158, 174, 190, 206, 222, 238, 254, 15, 31, 47, 63, 79, 95, 111, 127, 143, 159,
    175, 191, 207, 223, 239, 255);
begin
  huff_a46_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a47_cb;
const
  Values: array[0..7] of Integer = (
    4, 9, 5, 12, 9, 12, 15, 10);
begin
  huff_a47_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a47_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 2, 62, 63, 3, 4, 5, 6, 8, 54, 56, 57, 58, 59, 60, 61, 7, 9, 10, 11, 12, 13, 14, 53, 55,
    15, 16, 17, 18, 19, 20, 21, 36, 37, 39, 42, 52, 22, 25, 28, 35, 38, 40, 41, 43, 45, 46, 47, 48,
    49, 50, 51, 23, 24, 26, 27, 29, 30, 31, 33, 34, 44);
begin
  huff_a47_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a51_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 6, 2, 6, 18, 4, 26, 6, 12);
begin
  huff_a51_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a51_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 192, 48, 4, 1, 3, 16, 12, 208, 112, 52, 28, 13, 7, 80, 240, 68, 196, 20, 76, 204, 60, 65,
    193, 17, 49, 5, 67, 195, 19, 51, 15, 116, 220, 29, 55, 84, 212, 244, 92, 124, 252, 209, 113,
    241, 197, 21, 53, 77, 205, 221, 61, 83, 211, 115, 71, 199, 23, 119, 79, 31, 63, 81, 69, 85, 243,
    207, 255, 213, 117, 245, 93, 125, 253, 87, 215, 247, 95, 223, 127);
begin
  huff_a51_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a52_cb;
const
  Values: array[0..11] of Integer = (
    1, 10, 1, 0, 2, 2, 0, 4, 3, 8, 3, 2);
begin
  huff_a52_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a52_xlat;
const
  Values: array[0..24] of Integer = (
    0, 8, 56, 1, 7, 9, 57, 15, 63, 16, 2, 6, 48, 17, 49, 10, 58, 14, 23, 55, 50, 22, 62, 18, 54);
begin
  huff_a52_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a53_xlat;
const
  Values: array[0..6] of Integer = (
    0, 1, 2, 6, 7, 3, 5);
begin
  huff_a53_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a54_cb;
const
  Values: array[0..7] of Integer = (
    4, 9, 4, 7, 12, 19, 21, 58);
begin
  huff_a54_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a54_xlat;
const
  Values: array[0..120] of Integer = (
    0, 1, 15, 31, 16, 224, 240, 17, 241, 47, 255, 32, 33, 225, 2, 18, 242, 3, 243, 14, 46, 254, 63,
    48, 64, 208, 193, 209, 34, 194, 51, 227, 12, 204, 13, 29, 45, 253, 30, 62, 94, 239, 192, 82,
    178, 210, 67, 195, 211, 36, 69, 245, 75, 91, 251, 28, 61, 189, 221, 238, 191, 207, 223, 80, 176,
    49, 65, 81, 177, 50, 66, 226, 19, 35, 83, 179, 4, 20, 52, 68, 84, 180, 196, 212, 228, 244, 5,
    21, 37, 53, 85, 181, 197, 213, 229, 11, 27, 43, 59, 187, 203, 219, 235, 44, 60, 76, 92, 188,
    220, 236, 252, 77, 93, 205, 237, 78, 190, 206, 222, 79, 95);
begin
  huff_a54_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a55_cb;
const
  Values: array[0..7] of Integer = (
    1, 6, 1, 1, 1, 0, 3, 2);
begin
  huff_a55_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a55_xlat;
const
  Values: array[0..7] of Integer = (
    0, 1, 2, 3, 6, 7, 4, 5);
begin
  huff_a55_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a56_cb;
const
  Values: array[0..6] of Integer = (
    3, 7, 1, 8, 6, 8, 8);
begin
  huff_a56_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a56_xlat;
const
  Values: array[0..30] of Integer = (
    4, 0, 1, 2, 3, 28, 29, 30, 31, 5, 6, 7, 24, 25, 27, 8, 9, 14, 19, 21, 22, 23, 26, 10, 11, 12,
    13, 15, 17, 18, 20);
begin
  huff_a56_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a57_cb;
const
  Values: array[0..8] of Integer = (
    3, 9, 1, 5, 7, 8, 16, 22, 4);
begin
  huff_a57_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a57_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 2, 61, 62, 63, 3, 4, 5, 6, 58, 59, 60, 7, 8, 9, 10, 54, 55, 56, 57, 11, 12, 13, 14, 15,
    26, 27, 28, 36, 37, 38, 49, 50, 51, 52, 53, 16, 17, 18, 19, 20, 21, 23, 24, 25, 29, 30, 31, 33,
    34, 35, 39, 43, 44, 45, 46, 47, 48, 22, 40, 41, 42);
begin
  huff_a57_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a61_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 8, 0, 1, 16, 10, 29, 12, 4);
begin
  huff_a61_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a61_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 192, 16, 48, 4, 12, 1, 3, 112, 80, 208, 240, 68, 196, 20, 52, 76, 28, 60, 49, 5, 13, 19,
    7, 15, 116, 204, 220, 252, 65, 193, 17, 67, 195, 51, 84, 212, 244, 92, 124, 81, 209, 113, 241,
    69, 197, 21, 53, 77, 205, 29, 61, 83, 211, 115, 243, 71, 199, 23, 55, 79, 207, 31, 63, 85, 213,
    117, 245, 93, 221, 253, 87, 215, 119, 247, 255, 125, 95, 223, 127);
begin
  huff_a61_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a62_cb;
const
  Values: array[0..7] of Integer = (
    3, 8, 5, 2, 2, 9, 5, 2);
begin
  huff_a62_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a62_xlat;
const
  Values: array[0..24] of Integer = (
    0, 8, 56, 1, 7, 57, 15, 9, 63, 16, 48, 49, 2, 58, 6, 14, 23, 55, 17, 10, 50, 22, 62, 18, 54);
begin
  huff_a62_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a63_cb;
const
  Values: array[0..10] of Integer = (
    3, 11, 1, 1, 10, 4, 16, 29, 46, 75, 74);
begin
  huff_a63_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a63_xlat;
const
  Values: array[0..255] of Integer = (
    0, 64, 16, 80, 4, 68, 20, 1, 65, 5, 69, 85, 84, 17, 81, 21, 128, 144, 96, 36, 100, 164, 72, 97,
    149, 37, 165, 2, 66, 82, 22, 86, 32, 132, 148, 24, 88, 129, 145, 133, 101, 9, 73, 25, 89, 153,
    41, 105, 121, 93, 18, 98, 6, 70, 134, 102, 26, 90, 106, 71, 23, 192, 160, 224, 196, 212, 116, 8,
    120, 12, 76, 28, 92, 209, 33, 225, 113, 197, 229, 117, 181, 137, 189, 146, 34, 150, 166, 54, 10,
    74, 138, 154, 42, 122, 222, 110, 67, 19, 83, 35, 7, 119, 75, 27, 155, 107, 47, 208, 48, 112,
    228, 52, 244, 200, 152, 40, 104, 168, 232, 56, 184, 248, 156, 44, 108, 124, 161, 177, 213, 53,
    201, 217, 169, 233, 57, 185, 249, 205, 29, 45, 173, 125, 194, 210, 162, 178, 242, 198, 38, 118,
    182, 218, 170, 234, 58, 250, 14, 78, 46, 126, 190, 254, 3, 131, 99, 163, 179, 135, 87, 151, 215,
    39, 11, 139, 91, 43, 171, 207, 31, 159, 127, 191, 176, 240, 180, 136, 216, 140, 204, 220, 172,
    236, 60, 188, 252, 193, 49, 241, 245, 13, 77, 141, 157, 221, 109, 237, 61, 253, 130, 226, 50,
    114, 214, 230, 246, 202, 186, 142, 206, 30, 94, 158, 174, 238, 62, 195, 147, 211, 227, 51, 115,
    243, 199, 103, 167, 231, 55, 183, 247, 203, 219, 235, 59, 123, 187, 251, 15, 79, 143, 95, 223,
    111, 175, 239, 63, 255);
begin
  huff_a63_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a64_cb;
const
  Values: array[0..7] of Integer = (
    4, 9, 1, 7, 12, 36, 63, 2);
begin
  huff_a64_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a64_xlat;
const
  Values: array[0..120] of Integer = (
    0, 16, 32, 224, 240, 2, 14, 239, 48, 1, 17, 33, 49, 241, 18, 242, 30, 238, 223, 255, 64, 192,
    208, 209, 225, 34, 50, 66, 210, 226, 3, 19, 35, 179, 195, 227, 243, 228, 5, 245, 43, 12, 252,
    29, 45, 189, 221, 253, 46, 78, 222, 254, 15, 31, 47, 63, 80, 176, 65, 81, 177, 193, 82, 178,
    194, 51, 67, 83, 211, 4, 20, 36, 52, 68, 84, 180, 196, 212, 244, 21, 37, 53, 69, 85, 181, 197,
    213, 229, 11, 27, 59, 75, 91, 187, 203, 219, 235, 251, 28, 44, 60, 76, 92, 188, 204, 220, 236,
    13, 61, 77, 93, 205, 237, 62, 94, 190, 206, 79, 207, 95, 191);
begin
  huff_a64_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a65_cb;
const
  Values: array[0..7] of Integer = (
    2, 7, 3, 0, 1, 3, 4, 4);
begin
  huff_a65_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a65_xlat;
const
  Values: array[0..14] of Integer = (
    0, 1, 15, 14, 2, 3, 13, 4, 6, 10, 12, 5, 7, 9, 11);
begin
  huff_a65_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a66_cb;
const
  Values: array[0..10] of Integer = (
    2, 10, 1, 2, 2, 6, 8, 6, 3, 1, 2);
begin
  huff_a66_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a66_xlat;
const
  Values: array[0..30] of Integer = (
    0, 1, 31, 2, 30, 3, 4, 15, 17, 28, 29, 5, 6, 7, 8, 24, 25, 26, 27, 9, 10, 11, 21, 22, 23, 12,
    19, 20, 13, 14, 18);
begin
  huff_a66_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a67_cb;
const
  Values: array[0..9] of Integer = (
    2, 9, 1, 1, 3, 4, 6, 13, 25, 10);
begin
  huff_a67_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a67_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 2, 62, 63, 3, 4, 60, 61, 5, 6, 7, 57, 58, 59, 8, 9, 10, 11, 12, 13, 26, 38, 52, 53, 54,
    55, 56, 14, 15, 16, 17, 18, 19, 25, 27, 28, 29, 30, 31, 33, 34, 35, 36, 37, 39, 45, 46, 47, 48,
    49, 50, 51, 20, 21, 22, 23, 24, 40, 41, 42, 43, 44);
begin
  huff_a67_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a71_cb;
const
  Values: array[0..4] of Integer = (
    1, 3, 1, 1, 2);
begin
  huff_a71_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a72_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 4, 8, 3, 8, 24, 17, 12, 4);
begin
  huff_a72_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a72_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 16, 4, 1, 80, 68, 20, 84, 65, 17, 5, 21, 81, 69, 85, 128, 144, 32, 100, 8, 25, 2, 6, 96,
    132, 148, 36, 72, 24, 88, 129, 145, 33, 97, 133, 149, 37, 101, 9, 73, 89, 66, 18, 82, 70, 22,
    86, 160, 164, 152, 40, 104, 161, 165, 153, 41, 105, 150, 38, 102, 10, 74, 26, 90, 136, 168, 137,
    169, 130, 146, 34, 98, 134, 166, 42, 106, 162, 138, 154, 170);
begin
  huff_a72_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a73_cb;
const
  Values: array[0..10] of Integer = (
    2, 10, 1, 1, 5, 2, 8, 7, 13, 8, 4);
begin
  huff_a73_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a73_xlat;
const
  Values: array[0..48] of Integer = (
    0, 8, 56, 1, 57, 7, 15, 9, 63, 16, 48, 49, 2, 58, 6, 14, 23, 17, 10, 50, 13, 22, 62, 55, 24, 40,
    25, 41, 18, 42, 3, 59, 5, 21, 30, 31, 47, 26, 11, 43, 51, 53, 61, 46, 54, 19, 27, 29, 45);
begin
  huff_a73_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a74_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 4, 0, 4, 5, 9, 30, 45, 21, 2);
begin
  huff_a74_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a74_xlat;
const
  Values: array[0..120] of Integer = (
    0, 16, 240, 1, 15, 17, 241, 31, 255, 32, 224, 2, 242, 14, 33, 225, 18, 226, 30, 46, 254, 47,
    239, 48, 80, 176, 192, 208, 49, 177, 209, 34, 210, 3, 19, 227, 243, 244, 5, 229, 245, 11, 27,
    12, 13, 29, 45, 253, 62, 238, 63, 95, 223, 64, 65, 81, 193, 50, 66, 82, 178, 194, 35, 51, 179,
    195, 211, 4, 20, 36, 212, 228, 21, 37, 197, 213, 43, 59, 235, 251, 28, 44, 60, 92, 236, 252, 61,
    93, 221, 237, 78, 94, 190, 206, 222, 79, 191, 207, 67, 83, 52, 84, 180, 196, 53, 69, 85, 181,
    75, 91, 203, 219, 76, 188, 204, 220, 77, 189, 205, 68, 187);
begin
  huff_a74_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a75_cb;
const
  Values: array[0..6] of Integer = (
    2, 6, 1, 3, 3, 4, 4);
begin
  huff_a75_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a75_xlat;
const
  Values: array[0..14] of Integer = (
    0, 1, 14, 15, 2, 3, 13, 4, 6, 10, 12, 5, 7, 9, 11);
begin
  huff_a75_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_a76_cb;
const
  Values: array[0..11] of Integer = (
    3, 12, 1, 3, 4, 8, 10, 36, 60, 78, 48, 8);
begin
  huff_a76_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_a76_xlat;
const
  Values: array[0..255] of Integer = (
    0, 16, 1, 17, 32, 33, 2, 18, 48, 49, 65, 34, 3, 19, 35, 20, 64, 81, 97, 50, 66, 51, 4, 36, 21,
    22, 80, 96, 208, 113, 129, 209, 225, 241, 82, 98, 114, 210, 67, 83, 99, 211, 52, 68, 84, 5, 37,
    53, 69, 6, 38, 54, 23, 39, 24, 13, 29, 45, 61, 30, 46, 31, 112, 128, 224, 240, 145, 161, 193,
    130, 146, 194, 226, 242, 115, 131, 147, 227, 243, 100, 116, 132, 212, 228, 244, 85, 101, 213,
    229, 245, 70, 86, 102, 214, 7, 55, 71, 87, 8, 40, 56, 72, 25, 41, 57, 26, 42, 27, 28, 44, 60,
    77, 93, 109, 14, 62, 78, 94, 15, 47, 63, 79, 144, 160, 176, 192, 177, 162, 178, 163, 179, 195,
    148, 164, 180, 196, 117, 133, 149, 165, 197, 118, 134, 150, 230, 246, 103, 119, 135, 215, 231,
    247, 88, 104, 120, 136, 216, 232, 248, 9, 73, 89, 105, 217, 233, 249, 10, 58, 74, 90, 218, 234,
    11, 43, 59, 75, 219, 12, 76, 92, 108, 220, 125, 141, 157, 173, 189, 205, 110, 126, 142, 158,
    174, 190, 95, 111, 127, 143, 159, 175, 181, 166, 182, 198, 151, 167, 199, 152, 168, 184, 200,
    121, 137, 153, 169, 185, 201, 106, 122, 138, 154, 170, 202, 250, 91, 107, 123, 139, 203, 235,
    251, 124, 140, 156, 172, 188, 236, 252, 221, 237, 253, 206, 222, 238, 254, 191, 207, 223, 183,
    186, 155, 171, 187, 204, 239, 255);
begin
  huff_a76_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b01_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 2, 6, 0, 11, 13, 12, 24, 4, 8);
begin
  huff_b01_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b01_xlat;
const
  Values: array[0..80] of Integer = (
    0, 1, 3, 64, 192, 16, 48, 4, 12, 80, 208, 112, 240, 52, 28, 5, 13, 19, 7, 15, 68, 196, 20, 76,
    204, 60, 65, 193, 17, 49, 67, 195, 51, 84, 116, 220, 252, 113, 21, 77, 29, 211, 199, 55, 63,
    212, 244, 92, 124, 81, 209, 241, 69, 197, 85, 53, 205, 221, 61, 83, 115, 243, 71, 23, 119, 79,
    207, 31, 255, 245, 125, 215, 95, 213, 117, 93, 253, 87, 247, 223, 127);
begin
  huff_b01_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b02_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 4, 0, 8, 4, 9, 19, 13, 13, 10);
begin
  huff_b02_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b02_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 16, 4, 1, 80, 68, 20, 84, 65, 17, 5, 21, 128, 81, 69, 85, 144, 32, 96, 36, 8, 24, 9, 2,
    6, 132, 148, 100, 72, 88, 129, 145, 33, 97, 149, 37, 101, 25, 89, 66, 18, 70, 22, 86, 160, 164,
    40, 104, 133, 165, 73, 41, 105, 82, 10, 26, 90, 136, 152, 161, 137, 153, 169, 34, 98, 150, 38,
    102, 74, 106, 168, 130, 146, 162, 134, 166, 138, 154, 42, 170);
begin
  huff_b02_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b03_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 0, 0, 4, 0, 5, 12, 13, 14);
begin
  huff_b03_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b03_xlat;
const
  Values: array[0..48] of Integer = (
    0, 8, 56, 1, 7, 48, 9, 57, 15, 63, 16, 24, 40, 49, 2, 58, 3, 5, 6, 14, 23, 55, 17, 25, 41, 10,
    50, 11, 59, 13, 21, 61, 62, 31, 47, 18, 26, 42, 19, 27, 43, 51, 29, 45, 53, 22, 30, 46, 54);
begin
  huff_b03_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b04_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 4, 4, 5, 9, 30, 45, 21, 2);
begin
  huff_b04_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b04_xlat;
const
  Values: array[0..120] of Integer = (
    0, 16, 240, 1, 15, 17, 241, 31, 255, 32, 224, 2, 242, 14, 33, 225, 18, 226, 30, 46, 254, 47,
    239, 48, 80, 176, 192, 208, 49, 177, 209, 34, 210, 3, 19, 227, 243, 244, 5, 229, 245, 11, 27,
    12, 13, 29, 45, 253, 62, 238, 63, 95, 223, 64, 65, 81, 193, 50, 66, 82, 178, 194, 35, 51, 179,
    195, 211, 4, 20, 36, 212, 228, 21, 37, 197, 213, 43, 59, 235, 251, 28, 44, 60, 92, 236, 252, 61,
    93, 221, 237, 78, 94, 190, 206, 222, 79, 191, 207, 67, 83, 52, 84, 180, 196, 53, 69, 85, 181,
    75, 91, 203, 219, 76, 188, 204, 220, 77, 189, 205, 68, 187);
begin
  huff_b04_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b05_cb;
const
  Values: array[0..10] of Integer = (
    3, 11, 1, 4, 4, 4, 12, 30, 73, 75, 22);
begin
  huff_b05_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b05_xlat;
const
  Values: array[0..224] of Integer = (
    0, 16, 240, 1, 15, 17, 241, 31, 255, 32, 224, 2, 14, 48, 208, 33, 225, 18, 242, 3, 13, 30, 254,
    47, 239, 64, 96, 112, 144, 160, 192, 49, 209, 34, 50, 210, 226, 19, 35, 227, 243, 4, 6, 7, 9,
    10, 12, 29, 45, 253, 46, 62, 238, 63, 223, 80, 176, 65, 81, 97, 113, 145, 161, 177, 193, 66, 98,
    114, 146, 162, 194, 51, 147, 163, 211, 20, 36, 228, 244, 5, 21, 245, 22, 38, 214, 230, 246, 23,
    39, 215, 231, 247, 25, 41, 57, 233, 249, 26, 42, 234, 250, 11, 27, 251, 28, 44, 236, 252, 61,
    125, 157, 221, 237, 78, 110, 126, 158, 174, 206, 222, 79, 95, 111, 127, 159, 175, 191, 207, 82,
    178, 67, 83, 99, 115, 179, 195, 52, 68, 100, 116, 148, 164, 180, 196, 212, 37, 53, 101, 117,
    149, 165, 213, 229, 54, 70, 86, 102, 166, 182, 198, 55, 71, 87, 183, 199, 73, 89, 105, 185, 201,
    217, 58, 74, 90, 106, 170, 186, 202, 218, 43, 59, 107, 123, 155, 171, 219, 235, 60, 76, 108,
    124, 156, 172, 204, 220, 77, 93, 109, 173, 189, 205, 94, 190, 84, 69, 85, 181, 197, 118, 150,
    103, 119, 151, 167, 121, 153, 169, 122, 154, 75, 91, 187, 203, 92, 188);
begin
  huff_b05_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b07_cb;
const
  Values: array[0..8] of Integer = (
    3, 9, 3, 2, 4, 8, 23, 13, 10);
begin
  huff_b07_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b07_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 63, 2, 62, 3, 4, 60, 61, 5, 6, 7, 8, 56, 57, 58, 59, 9, 10, 11, 12, 25, 26, 27, 28, 29,
    30, 31, 33, 34, 35, 36, 37, 38, 39, 51, 52, 53, 54, 55, 13, 14, 15, 16, 17, 18, 19, 45, 46, 47,
    48, 49, 50, 20, 21, 22, 23, 24, 40, 41, 42, 43, 44);
begin
  huff_b07_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b12_cb;
const
  Values: array[0..9] of Integer = (
    3, 10, 1, 3, 12, 0, 30, 9, 18, 8);
begin
  huff_b12_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b12_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 4, 1, 16, 80, 68, 20, 84, 65, 17, 81, 5, 69, 21, 85, 128, 144, 32, 96, 132, 148, 36, 100,
    8, 72, 24, 129, 145, 97, 133, 149, 37, 101, 9, 73, 25, 89, 2, 66, 18, 82, 6, 70, 22, 86, 164,
    88, 104, 33, 165, 41, 105, 26, 90, 160, 136, 152, 40, 161, 137, 153, 169, 146, 34, 98, 134, 150,
    38, 102, 10, 74, 106, 168, 130, 162, 166, 138, 154, 42, 170);
begin
  huff_b12_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b14_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 4, 0, 3, 5, 16, 28, 34, 26, 4);
begin
  huff_b14_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b14_xlat;
const
  Values: array[0..120] of Integer = (
    0, 16, 240, 1, 15, 241, 31, 255, 32, 224, 17, 2, 14, 48, 80, 176, 208, 33, 225, 18, 242, 3, 5,
    11, 13, 30, 254, 47, 239, 64, 192, 49, 81, 177, 193, 209, 34, 82, 226, 19, 243, 4, 21, 245, 27,
    235, 251, 12, 29, 253, 46, 94, 238, 63, 95, 191, 223, 65, 50, 66, 178, 210, 35, 83, 179, 227,
    20, 36, 228, 244, 37, 53, 213, 229, 43, 59, 219, 28, 44, 188, 236, 252, 45, 189, 237, 62, 78,
    190, 222, 79, 207, 194, 51, 67, 195, 211, 52, 68, 84, 180, 212, 69, 85, 197, 75, 203, 60, 76,
    92, 204, 220, 61, 77, 93, 205, 221, 206, 196, 181, 91, 187);
begin
  huff_b14_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b16_cb;
const
  Values: array[0..10] of Integer = (
    4, 12, 4, 4, 9, 13, 37, 76, 72, 39, 2);
begin
  huff_b16_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b16_xlat;
const
  Values: array[0..255] of Integer = (
    0, 16, 1, 17, 32, 33, 2, 18, 48, 49, 65, 34, 50, 3, 19, 35, 20, 64, 81, 97, 66, 82, 51, 67, 4,
    36, 52, 21, 37, 22, 80, 96, 112, 113, 129, 209, 225, 98, 114, 130, 210, 83, 99, 115, 211, 68,
    84, 5, 53, 69, 85, 6, 38, 54, 7, 23, 39, 55, 24, 40, 25, 29, 45, 61, 30, 46, 31, 128, 144, 208,
    224, 240, 145, 161, 177, 193, 241, 146, 162, 178, 194, 226, 242, 131, 147, 163, 195, 227, 243,
    100, 116, 132, 148, 212, 228, 244, 101, 117, 133, 213, 229, 70, 86, 102, 118, 214, 230, 71, 87,
    103, 215, 8, 56, 72, 88, 9, 41, 57, 73, 10, 26, 42, 58, 27, 43, 12, 28, 44, 60, 13, 77, 93, 109,
    125, 14, 62, 78, 94, 110, 15, 47, 63, 79, 160, 176, 192, 179, 164, 180, 196, 149, 165, 181, 197,
    245, 134, 150, 166, 182, 198, 246, 119, 135, 151, 167, 199, 231, 247, 104, 120, 136, 152, 216,
    232, 248, 89, 105, 121, 137, 217, 233, 249, 74, 90, 106, 122, 218, 234, 11, 59, 75, 91, 219,
    235, 76, 92, 108, 124, 140, 220, 141, 157, 173, 189, 205, 126, 142, 158, 174, 190, 95, 111, 127,
    143, 159, 183, 168, 184, 200, 153, 169, 185, 201, 138, 154, 170, 186, 202, 250, 107, 123, 139,
    155, 171, 187, 203, 251, 156, 172, 188, 204, 236, 252, 221, 237, 253, 206, 222, 238, 254, 175,
    191, 207, 223, 239, 255);
begin
  huff_b16_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b26_cb;
const
  Values: array[0..11] of Integer = (
    3, 12, 2, 2, 4, 5, 11, 26, 67, 78, 51, 10);
begin
  huff_b26_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b26_xlat;
const
  Values: array[0..255] of Integer = (
    0, 1, 16, 17, 32, 33, 2, 18, 48, 49, 34, 3, 19, 64, 65, 81, 50, 66, 35, 51, 4, 20, 36, 21, 80,
    97, 113, 209, 225, 82, 98, 210, 67, 83, 211, 52, 68, 5, 37, 53, 6, 22, 38, 23, 24, 29, 45, 61,
    30, 46, 96, 112, 128, 208, 224, 240, 129, 145, 161, 193, 241, 114, 130, 146, 194, 226, 242, 99,
    115, 227, 243, 84, 100, 116, 212, 228, 244, 69, 85, 101, 213, 229, 245, 54, 70, 86, 214, 230, 7,
    39, 55, 71, 215, 8, 40, 56, 25, 41, 26, 27, 28, 44, 13, 77, 93, 109, 125, 14, 62, 78, 94, 110,
    15, 31, 47, 63, 79, 144, 160, 192, 177, 162, 178, 131, 147, 163, 179, 195, 132, 148, 164, 196,
    117, 133, 149, 197, 102, 118, 134, 150, 198, 246, 87, 103, 119, 231, 247, 72, 88, 104, 120, 216,
    232, 248, 9, 57, 73, 89, 217, 233, 249, 10, 42, 58, 74, 218, 234, 11, 43, 59, 219, 235, 12, 60,
    76, 92, 108, 220, 141, 157, 173, 189, 205, 126, 142, 158, 174, 190, 206, 95, 111, 127, 143, 159,
    175, 176, 180, 165, 181, 166, 182, 135, 151, 167, 183, 199, 136, 152, 168, 200, 105, 121, 137,
    153, 169, 201, 90, 106, 122, 154, 202, 250, 75, 91, 107, 123, 203, 251, 124, 140, 156, 172, 188,
    204, 236, 252, 221, 237, 253, 222, 238, 254, 191, 207, 223, 239, 184, 185, 138, 170, 186, 139,
    155, 171, 187, 255);
begin
  huff_b26_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b32_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 4, 6, 7, 10, 22, 11, 16, 4);
begin
  huff_b32_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b32_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 16, 4, 1, 80, 68, 20, 65, 17, 5, 128, 84, 81, 69, 21, 85, 2, 144, 32, 96, 132, 36, 8, 24,
    9, 18, 6, 160, 148, 100, 72, 88, 129, 145, 33, 97, 133, 149, 37, 101, 73, 25, 89, 66, 82, 70,
    22, 86, 10, 164, 40, 104, 161, 165, 41, 105, 38, 74, 26, 90, 136, 152, 168, 137, 153, 169, 130,
    146, 34, 98, 134, 150, 102, 154, 42, 106, 162, 166, 138, 170);
begin
  huff_b32_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b33_cb;
const
  Values: array[0..12] of Integer = (
    2, 12, 1, 0, 0, 4, 11, 8, 28, 92, 97, 13, 2);
begin
  huff_b33_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b33_xlat;
const
  Values: array[0..255] of Integer = (
    0, 64, 16, 4, 1, 80, 68, 20, 84, 65, 17, 81, 5, 69, 21, 85, 32, 149, 101, 73, 89, 82, 70, 22,
    128, 144, 96, 132, 148, 36, 100, 164, 8, 72, 24, 88, 129, 145, 33, 97, 133, 37, 9, 25, 105, 2,
    66, 18, 6, 86, 90, 87, 208, 116, 104, 92, 193, 213, 165, 229, 117, 181, 245, 153, 217, 169, 233,
    121, 185, 249, 29, 93, 157, 221, 109, 173, 237, 125, 189, 253, 130, 146, 210, 98, 150, 214, 38,
    102, 166, 230, 118, 182, 246, 10, 74, 26, 154, 218, 42, 106, 170, 234, 122, 186, 250, 94, 158,
    222, 110, 174, 238, 126, 190, 254, 3, 19, 83, 23, 151, 215, 103, 167, 231, 119, 183, 247, 91,
    155, 219, 107, 171, 235, 123, 187, 251, 95, 159, 223, 111, 175, 239, 127, 191, 255, 192, 160,
    224, 48, 196, 212, 228, 52, 180, 244, 136, 200, 152, 216, 40, 168, 232, 56, 120, 184, 248, 12,
    76, 28, 156, 220, 108, 172, 236, 124, 188, 252, 209, 161, 225, 49, 113, 177, 241, 197, 53, 137,
    201, 41, 57, 13, 77, 141, 205, 45, 61, 34, 162, 226, 114, 178, 242, 134, 198, 54, 138, 202, 58,
    14, 78, 142, 206, 30, 46, 62, 67, 131, 147, 211, 35, 99, 163, 227, 115, 179, 243, 7, 71, 135,
    199, 39, 55, 75, 139, 203, 27, 43, 59, 79, 143, 207, 31, 112, 176, 240, 140, 204, 44, 60, 194,
    50, 195, 15, 47, 63, 51, 11);
begin
  huff_b33_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b35_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 0, 4, 6, 6, 14, 42, 63, 59, 30);
begin
  huff_b35_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b35_xlat;
const
  Values: array[0..224] of Integer = (
    0, 16, 240, 1, 15, 17, 241, 2, 14, 31, 255, 32, 224, 33, 242, 254, 239, 48, 208, 225, 18, 34,
    226, 3, 13, 29, 30, 46, 238, 47, 223, 64, 96, 112, 144, 160, 176, 192, 49, 113, 145, 193, 209,
    50, 210, 19, 227, 243, 4, 5, 6, 7, 23, 247, 9, 25, 10, 26, 250, 12, 28, 45, 237, 253, 62, 126,
    222, 63, 111, 127, 159, 175, 207, 80, 65, 81, 97, 161, 177, 98, 114, 146, 162, 194, 35, 51, 99,
    115, 147, 163, 211, 20, 36, 52, 212, 228, 244, 21, 245, 22, 38, 214, 230, 246, 39, 55, 71, 231,
    41, 57, 201, 217, 233, 249, 42, 234, 11, 27, 251, 44, 124, 236, 252, 61, 77, 109, 125, 221, 78,
    94, 110, 158, 174, 206, 79, 95, 66, 82, 178, 67, 179, 195, 68, 100, 116, 148, 164, 37, 53, 101,
    117, 149, 165, 229, 54, 70, 102, 118, 150, 166, 182, 198, 87, 167, 183, 199, 215, 89, 169, 185,
    58, 74, 106, 202, 218, 43, 59, 107, 155, 171, 219, 235, 60, 108, 156, 172, 204, 220, 93, 157,
    173, 189, 205, 190, 191, 83, 84, 180, 196, 69, 85, 181, 197, 213, 86, 103, 119, 151, 73, 105,
    121, 153, 90, 122, 154, 170, 186, 75, 91, 123, 187, 203, 76, 92, 188);
begin
  huff_b35_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b37_cb;
const
  Values: array[0..12] of Integer = (
    1, 11, 1, 0, 2, 0, 2, 2, 6, 17, 14, 13, 6);
begin
  huff_b37_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b37_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 63, 2, 62, 3, 61, 4, 5, 6, 58, 59, 60, 7, 8, 9, 10, 25, 26, 27, 28, 29, 34, 35, 37, 38,
    39, 55, 56, 57, 11, 13, 14, 15, 30, 31, 33, 36, 49, 50, 51, 52, 53, 54, 12, 16, 17, 18, 19, 21,
    41, 43, 44, 45, 46, 47, 48, 20, 22, 23, 24, 40, 42);
begin
  huff_b37_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b41_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 1, 7, 0, 20, 4, 10, 24, 2, 12);
begin
  huff_b41_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b41_xlat;
const
  Values: array[0..80] of Integer = (
    0, 1, 64, 192, 16, 48, 4, 12, 3, 80, 208, 112, 240, 196, 20, 52, 76, 28, 60, 193, 17, 49, 5, 13,
    195, 19, 51, 7, 15, 68, 204, 65, 67, 84, 116, 220, 252, 113, 21, 77, 29, 55, 63, 212, 244, 92,
    124, 81, 209, 241, 69, 197, 53, 205, 221, 61, 83, 211, 115, 243, 71, 199, 23, 119, 79, 207, 31,
    85, 255, 213, 117, 245, 93, 125, 253, 87, 215, 247, 95, 223, 127);
begin
  huff_b41_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b42_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 0, 1, 3, 2, 3, 7, 4, 4);
begin
  huff_b42_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b42_xlat;
const
  Values: array[0..24] of Integer = (
    0, 7, 8, 56, 1, 57, 15, 16, 9, 63, 48, 49, 2, 58, 6, 14, 23, 17, 10, 62, 55, 18, 50, 22, 54);
begin
  huff_b42_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b43_cb;
const
  Values: array[0..9] of Integer = (
    2, 9, 1, 1, 3, 4, 9, 15, 12, 4);
begin
  huff_b43_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b43_xlat;
const
  Values: array[0..48] of Integer = (
    0, 7, 8, 56, 1, 9, 57, 15, 63, 16, 48, 49, 2, 58, 6, 14, 23, 55, 24, 40, 17, 25, 41, 10, 3, 11,
    59, 5, 13, 61, 62, 31, 47, 18, 26, 42, 50, 19, 51, 21, 53, 22, 30, 46, 54, 27, 43, 29, 45);
begin
  huff_b43_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b47_cb;
const
  Values: array[0..9] of Integer = (
    2, 9, 1, 1, 3, 4, 6, 14, 22, 12);
begin
  huff_b47_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b47_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 2, 62, 63, 3, 4, 60, 61, 5, 6, 7, 57, 58, 59, 8, 9, 10, 11, 12, 26, 27, 37, 38, 52, 53,
    54, 55, 56, 13, 14, 15, 16, 17, 18, 25, 28, 29, 30, 31, 33, 34, 35, 36, 39, 46, 47, 48, 49, 50,
    51, 19, 20, 21, 22, 23, 24, 40, 41, 42, 43, 44, 45);
begin
  huff_b47_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b52_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 0, 1, 3, 2, 3, 7, 4, 4);
begin
  huff_b52_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b52_xlat;
const
  Values: array[0..24] of Integer = (
    0, 1, 8, 56, 7, 57, 15, 48, 9, 63, 16, 49, 2, 58, 6, 14, 23, 17, 10, 62, 55, 18, 50, 22, 54);
begin
  huff_b52_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b53_cb;
const
  Values: array[0..6] of Integer = (
    1, 5, 1, 1, 1, 0, 4);
begin
  huff_b53_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b53_xlat;
const
  Values: array[0..6] of Integer = (
    0, 7, 1, 2, 3, 5, 6);
begin
  huff_b53_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b56_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 0, 2, 0, 2, 4, 11, 9, 2);
begin
  huff_b56_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b56_xlat;
const
  Values: array[0..30] of Integer = (
    0, 1, 31, 2, 30, 3, 4, 13, 29, 5, 6, 7, 14, 15, 17, 18, 19, 26, 27, 28, 8, 9, 12, 20, 21, 22,
    23, 24, 25, 10, 11);
begin
  huff_b56_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b62_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 2, 3, 5, 12, 14, 18, 15, 9, 2);
begin
  huff_b62_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b62_xlat;
const
  Values: array[0..80] of Integer = (
    0, 64, 1, 16, 4, 2, 128, 80, 144, 5, 6, 32, 96, 68, 20, 84, 36, 8, 24, 65, 17, 21, 9, 160, 132,
    148, 100, 164, 40, 81, 69, 85, 25, 18, 22, 10, 26, 72, 88, 104, 129, 145, 33, 97, 133, 149, 37,
    101, 73, 89, 41, 105, 66, 70, 86, 136, 152, 168, 161, 165, 153, 169, 82, 34, 38, 102, 74, 90,
    42, 106, 137, 130, 146, 98, 134, 150, 166, 138, 170, 162, 154);
begin
  huff_b62_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b63_cb;
const
  Values: array[0..6] of Integer = (
    1, 5, 1, 1, 1, 0, 4);
begin
  huff_b63_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b63_xlat;
const
  Values: array[0..6] of Integer = (
    0, 1, 7, 2, 3, 5, 6);
begin
  huff_b63_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b64_cb;
const
  Values: array[0..6] of Integer = (
    1, 5, 1, 1, 1, 1, 2);
begin
  huff_b64_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b64_xlat;
const
  Values: array[0..5] of Integer = (
    1, 0, 2, 5, 3, 4);
begin
  huff_b64_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b65_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 2, 2, 2, 6, 12, 34, 92, 54, 20);
begin
  huff_b65_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b65_xlat;
const
  Values: array[0..224] of Integer = (
    0, 240, 1, 16, 15, 17, 241, 32, 224, 2, 14, 31, 255, 208, 33, 225, 18, 242, 7, 10, 13, 30, 254,
    47, 239, 48, 112, 144, 160, 192, 113, 145, 193, 209, 50, 146, 226, 3, 19, 99, 4, 6, 230, 231,
    247, 9, 25, 57, 250, 12, 28, 221, 237, 253, 46, 126, 158, 63, 159, 64, 80, 96, 176, 49, 65, 97,
    161, 177, 34, 66, 114, 162, 178, 194, 210, 35, 51, 115, 163, 195, 211, 227, 243, 20, 36, 52, 68,
    116, 212, 228, 5, 37, 69, 101, 149, 165, 22, 38, 70, 118, 166, 182, 198, 214, 246, 23, 39, 55,
    71, 103, 167, 215, 41, 105, 185, 217, 233, 249, 26, 42, 58, 154, 202, 218, 234, 11, 27, 59, 107,
    235, 251, 44, 108, 236, 252, 29, 45, 77, 109, 157, 173, 62, 78, 110, 174, 206, 238, 79, 95, 111,
    223, 81, 82, 98, 67, 147, 179, 84, 148, 164, 244, 21, 117, 181, 229, 245, 54, 86, 102, 150, 87,
    119, 73, 89, 169, 201, 74, 90, 106, 122, 170, 186, 43, 75, 123, 155, 171, 219, 60, 76, 124, 156,
    172, 188, 204, 61, 93, 125, 189, 205, 94, 190, 222, 191, 207, 83, 100, 180, 196, 53, 85, 197,
    213, 151, 183, 199, 121, 153, 91, 187, 203, 92, 220, 127, 175);
begin
  huff_b65_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b66_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 3, 0, 3, 3, 10, 40, 85, 61, 50);
begin
  huff_b66_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b66_xlat;
const
  Values: array[0..255] of Integer = (
    0, 16, 1, 17, 33, 2, 18, 32, 34, 19, 48, 49, 65, 209, 225, 50, 82, 3, 35, 45, 64, 80, 96, 128,
    208, 224, 81, 97, 241, 66, 98, 210, 226, 242, 51, 67, 195, 211, 227, 4, 20, 212, 244, 37, 53,
    22, 23, 247, 216, 28, 60, 13, 29, 61, 93, 14, 30, 46, 126, 47, 192, 240, 113, 129, 145, 193,
    114, 130, 146, 178, 194, 83, 99, 115, 147, 163, 243, 36, 68, 100, 132, 164, 180, 5, 21, 149,
    213, 6, 38, 54, 70, 150, 214, 230, 246, 7, 39, 55, 215, 231, 8, 24, 40, 56, 232, 248, 9, 25, 41,
    233, 249, 10, 26, 202, 218, 234, 11, 27, 219, 235, 251, 44, 76, 92, 124, 140, 77, 109, 141, 157,
    253, 62, 94, 110, 142, 158, 238, 15, 31, 63, 79, 95, 111, 127, 207, 112, 161, 162, 131, 179, 52,
    116, 196, 228, 85, 101, 133, 165, 197, 229, 245, 86, 102, 118, 134, 166, 198, 87, 103, 119, 151,
    167, 72, 136, 152, 73, 89, 121, 153, 58, 74, 138, 186, 250, 43, 123, 12, 172, 188, 204, 236,
    125, 173, 189, 221, 78, 190, 206, 254, 143, 159, 175, 191, 223, 239, 255, 144, 160, 176, 177,
    84, 148, 69, 117, 181, 182, 71, 135, 183, 199, 88, 104, 120, 168, 184, 200, 57, 105, 137, 169,
    185, 201, 217, 42, 90, 106, 122, 154, 170, 59, 75, 91, 107, 139, 155, 171, 187, 203, 108, 156,
    220, 252, 205, 237, 174, 222);
begin
  huff_b66_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b67_cb;
const
  Values: array[0..9] of Integer = (
    2, 9, 1, 2, 1, 4, 7, 10, 26, 12);
begin
  huff_b67_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b67_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 63, 62, 2, 3, 60, 61, 4, 5, 6, 7, 57, 58, 59, 8, 9, 10, 11, 12, 52, 53, 54, 55, 56, 13,
    14, 15, 16, 17, 18, 25, 26, 27, 28, 29, 30, 31, 33, 34, 35, 36, 37, 38, 39, 46, 47, 48, 49, 50,
    51, 19, 20, 21, 22, 23, 24, 40, 41, 42, 43, 44, 45);
begin
  huff_b67_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b71_cb;
const
  Values: array[0..13] of Integer = (
    1, 12, 1, 0, 0, 1, 7, 0, 19, 5, 13, 23, 0, 12);
begin
  huff_b71_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b71_xlat;
const
  Values: array[0..80] of Integer = (
    0, 3, 64, 192, 16, 48, 4, 12, 1, 80, 208, 112, 240, 196, 20, 52, 76, 28, 60, 193, 17, 49, 5, 13,
    19, 51, 7, 15, 68, 204, 65, 67, 195, 84, 116, 220, 252, 241, 197, 21, 29, 83, 199, 55, 79, 63,
    212, 244, 92, 124, 81, 209, 113, 69, 85, 53, 77, 205, 221, 61, 211, 115, 243, 71, 23, 119, 207,
    31, 255, 213, 117, 245, 93, 125, 253, 87, 215, 247, 95, 223, 127);
begin
  huff_b71_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b73_cb;
const
  Values: array[0..12] of Integer = (
    1, 11, 1, 0, 0, 0, 1, 4, 9, 4, 103, 110, 24);
begin
  huff_b73_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b73_xlat;
const
  Values: array[0..255] of Integer = (
    0, 64, 16, 4, 1, 5, 80, 20, 84, 65, 17, 81, 69, 21, 85, 68, 149, 106, 3, 128, 192, 144, 208,
    148, 212, 36, 100, 88, 145, 161, 133, 213, 37, 101, 165, 229, 117, 181, 245, 25, 89, 153, 217,
    105, 169, 233, 121, 185, 249, 77, 93, 157, 221, 109, 173, 237, 125, 189, 253, 2, 66, 82, 6, 70,
    22, 86, 150, 214, 38, 102, 166, 230, 118, 182, 246, 26, 90, 154, 218, 170, 234, 122, 186, 250,
    94, 158, 222, 110, 174, 238, 126, 190, 254, 7, 71, 87, 151, 215, 103, 167, 231, 119, 183, 247,
    91, 155, 219, 107, 171, 235, 123, 187, 251, 95, 159, 223, 111, 175, 239, 127, 191, 255, 32, 96,
    112, 176, 240, 132, 196, 164, 228, 116, 180, 244, 8, 136, 24, 152, 216, 104, 168, 232, 120, 184,
    248, 28, 92, 156, 220, 108, 172, 236, 60, 124, 188, 252, 129, 209, 33, 97, 225, 113, 177, 241,
    197, 53, 9, 73, 137, 201, 41, 57, 13, 141, 205, 29, 45, 61, 146, 210, 34, 98, 162, 226, 114,
    178, 242, 134, 198, 54, 10, 74, 138, 202, 42, 58, 14, 78, 142, 206, 30, 46, 62, 19, 83, 147,
    211, 99, 163, 227, 115, 179, 243, 135, 199, 23, 39, 55, 11, 75, 139, 203, 27, 43, 59, 15, 79,
    143, 207, 31, 47, 63, 160, 224, 48, 52, 72, 200, 40, 56, 12, 76, 140, 204, 44, 193, 49, 130,
    194, 18, 50, 67, 131, 195, 35, 51);
begin
  huff_b73_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b74_cb;
const
  Values: array[0..7] of Integer = (
    1, 6, 1, 0, 2, 2, 2, 4);
begin
  huff_b74_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b74_xlat;
const
  Values: array[0..10] of Integer = (
    0, 1, 15, 2, 14, 5, 13, 3, 4, 11, 12);
begin
  huff_b74_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b75_cb;
const
  Values: array[0..12] of Integer = (
    2, 12, 1, 4, 0, 0, 0, 8, 11, 24, 53, 64, 60);
begin
  huff_b75_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b75_xlat;
const
  Values: array[0..224] of Integer = (
    0, 16, 240, 1, 15, 32, 224, 17, 241, 2, 14, 31, 255, 208, 33, 225, 18, 242, 3, 13, 30, 254, 47,
    239, 48, 64, 96, 112, 144, 160, 192, 49, 209, 34, 226, 19, 243, 4, 6, 7, 9, 12, 29, 253, 46,
    238, 63, 223, 80, 176, 65, 97, 113, 145, 161, 193, 50, 98, 114, 146, 162, 210, 35, 211, 227, 20,
    244, 5, 22, 38, 230, 246, 23, 39, 231, 247, 25, 41, 249, 10, 26, 42, 250, 11, 28, 44, 252, 45,
    61, 237, 62, 78, 126, 158, 222, 79, 111, 127, 159, 175, 207, 81, 177, 66, 82, 178, 194, 51, 99,
    115, 147, 163, 179, 195, 36, 52, 116, 164, 212, 228, 21, 37, 101, 149, 229, 245, 54, 214, 55,
    71, 199, 215, 57, 89, 185, 201, 217, 233, 58, 106, 218, 234, 27, 43, 155, 171, 235, 251, 108,
    124, 156, 172, 236, 77, 109, 125, 157, 173, 189, 221, 94, 110, 174, 206, 95, 67, 83, 68, 84,
    100, 148, 180, 196, 53, 69, 85, 117, 165, 181, 197, 213, 70, 86, 102, 118, 150, 166, 182, 198,
    87, 103, 119, 151, 167, 183, 73, 105, 121, 153, 169, 74, 90, 122, 154, 170, 186, 202, 59, 75,
    91, 107, 123, 187, 203, 219, 60, 76, 92, 188, 204, 220, 93, 205, 190, 191);
begin
  huff_b75_xlat := CopyIntegerTable(Values);
end;

procedure Init_huff_b77_cb;
const
  Values: array[0..11] of Integer = (
    2, 11, 1, 0, 4, 6, 10, 12, 7, 15, 4, 4);
begin
  huff_b77_cb := CopyIntegerTable(Values);
end;

procedure Init_huff_b77_xlat;
const
  Values: array[0..62] of Integer = (
    0, 1, 2, 62, 63, 3, 4, 5, 59, 60, 61, 6, 7, 8, 9, 10, 54, 55, 56, 57, 58, 11, 12, 13, 14, 15,
    16, 47, 49, 50, 51, 52, 53, 17, 18, 19, 20, 45, 46, 48, 21, 22, 23, 24, 25, 26, 27, 37, 38, 39,
    40, 41, 42, 43, 44, 28, 29, 30, 35, 31, 33, 34, 36);
begin
  huff_b77_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_spectra_tabs;
begin
  atrac3p_spectra_tabs := TArray<TATSpecCodeTab>.Create(TATSpecCodeTab.Create(1, 4, 2, 1, -1, huff_a01_cb,
      huff_a01_xlat), TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_a02_cb, huff_a02_xlat),
    TATSpecCodeTab.Create(1, 2, 3, 1, -1, huff_a03_cb, huff_a03_xlat), TATSpecCodeTab.Create(1, 1, 3, 0, -1,
      huff_a04_cb, huff_a04_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a05_cb, huff_a05_xlat),
    TATSpecCodeTab.Create(1, 1, 4, 0, -1, huff_a06_cb, huff_a06_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, -1,
      huff_a07_cb, huff_a07_xlat), TATSpecCodeTab.Create(4, 4, 2, 1, -1, huff_a11_cb, huff_a11_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_a12_cb, huff_a12_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, -1,
      huff_a13_cb, huff_a13_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a14_cb, huff_a14_xlat),
    TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a15_cb, huff_a15_xlat), TATSpecCodeTab.Create(1, 2, 4, 0, -1,
      huff_a16_cb, huff_a16_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_a17_cb, huff_a17_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 1, -1, huff_a21_cb, huff_a21_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, -1,
      huff_a22_cb, huff_a22_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, -1, huff_a23_cb, huff_a23_xlat),
    TATSpecCodeTab.Create(1, 1, 3, 0, -1, huff_a24_cb, nil), TATSpecCodeTab.Create(1, 1, 3, 0, -1,
      huff_a25_cb, huff_a25_xlat), TATSpecCodeTab.Create(1, 2, 4, 0, -1, huff_a26_cb, huff_a26_xlat),
    TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_a27_cb, huff_a27_xlat), TATSpecCodeTab.Create(1, 2, 2, 1, -1,
      huff_a31_cb, huff_a31_xlat), TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_a32_cb, huff_a32_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_a33_cb, huff_a33_xlat), TATSpecCodeTab.Create(1, 1, 3, 0, -1,
      huff_a34_cb, huff_a34_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a35_cb, huff_a35_xlat),
    TATSpecCodeTab.Create(1, 2, 4, 0, -1, huff_a36_cb, huff_a36_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, -1,
      huff_a37_cb, huff_a37_xlat), TATSpecCodeTab.Create(1, 4, 2, 1, -1, huff_a41_cb, huff_a41_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_a42_cb, huff_a42_xlat), TATSpecCodeTab.Create(1, 1, 3, 1, -1,
      huff_a43_cb, huff_a43_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a44_cb, huff_a44_xlat),
    TATSpecCodeTab.Create(1, 1, 3, 0, -1, huff_a45_cb, huff_a45_xlat), TATSpecCodeTab.Create(1, 2, 4, 0, -1,
      huff_a46_cb, huff_a46_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_a47_cb, huff_a47_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 1, -1, huff_a51_cb, huff_a51_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, -1,
      huff_a52_cb, huff_a52_xlat), TATSpecCodeTab.Create(1, 1, 3, 1, -1, huff_a43_cb, huff_a53_xlat),
    TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a54_cb, huff_a54_xlat), TATSpecCodeTab.Create(1, 1, 3, 0, -1,
      huff_a55_cb, huff_a55_xlat), TATSpecCodeTab.Create(1, 1, 5, 1, -1, huff_a56_cb, huff_a56_xlat),
    TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_a57_cb, huff_a57_xlat), TATSpecCodeTab.Create(2, 4, 2, 1, -1,
      huff_a61_cb, huff_a61_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, -1, huff_a62_cb, huff_a62_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_a63_cb, huff_a63_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1,
      huff_a64_cb, huff_a64_xlat), TATSpecCodeTab.Create(1, 1, 4, 1, -1, huff_a65_cb, huff_a65_xlat),
    TATSpecCodeTab.Create(1, 1, 5, 1, -1, huff_a66_cb, huff_a66_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, -1,
      huff_a67_cb, huff_a67_xlat), TATSpecCodeTab.Create(1, 2, 1, 0, -1, huff_a71_cb, nil),
    TATSpecCodeTab.Create(2, 4, 2, 0, -1, huff_a72_cb, huff_a72_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, -1,
      huff_a73_cb, huff_a73_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_a74_cb, huff_a74_xlat),
    TATSpecCodeTab.Create(1, 1, 4, 1, -1, huff_a75_cb, huff_a75_xlat), TATSpecCodeTab.Create(2, 2, 4, 0, -1,
      huff_a76_cb, huff_a76_xlat), TATSpecCodeTab.Create(4, 1, 6, 1, 6, nil, nil), TATSpecCodeTab.Create(4, 4,
      2, 1, -1, huff_b01_cb, huff_b01_xlat), TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_b02_cb, huff_b02_xlat),
    TATSpecCodeTab.Create(4, 2, 3, 1, -1, huff_b03_cb, huff_b03_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1,
      huff_b04_cb, huff_b04_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_b05_cb, huff_b05_xlat),
    TATSpecCodeTab.Create(1, 1, 4, 0, 5, nil, nil), TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_b07_cb,
      huff_b07_xlat), TATSpecCodeTab.Create(1, 4, 2, 1, 14, nil, nil), TATSpecCodeTab.Create(1, 4, 2, 0, -1,
      huff_b12_cb, huff_b12_xlat), TATSpecCodeTab.Create(1, 2, 3, 1, 9, nil, nil), TATSpecCodeTab.Create(1, 2,
      4, 1, -1, huff_b14_cb, huff_b14_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, 11, nil, nil),
    TATSpecCodeTab.Create(1, 2, 4, 0, -1, huff_b16_cb, huff_b16_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, 6,
      nil, nil), TATSpecCodeTab.Create(4, 4, 2, 1, 28, nil, nil), TATSpecCodeTab.Create(4, 4, 2, 0, 22, nil,
      nil), TATSpecCodeTab.Create(1, 2, 3, 1, 2, nil, nil), TATSpecCodeTab.Create(1, 2, 4, 1, 31, nil, nil),
    TATSpecCodeTab.Create(2, 2, 4, 1, 60, nil, nil), TATSpecCodeTab.Create(2, 2, 4, 0, -1, huff_b26_cb,
      huff_b26_xlat), TATSpecCodeTab.Create(4, 1, 6, 1, 6, nil, nil), TATSpecCodeTab.Create(1, 4, 2, 1, 35, nil,
      nil), TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_b32_cb, huff_b32_xlat), TATSpecCodeTab.Create(1, 4, 2, 0,
      -1, huff_b33_cb, huff_b33_xlat), TATSpecCodeTab.Create(2, 2, 4, 1, 59, nil, nil), TATSpecCodeTab.Create(1,
      2, 4, 1, -1, huff_b35_cb, huff_b35_xlat), TATSpecCodeTab.Create(1, 2, 4, 0, 75, nil, nil),
    TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_b37_cb, huff_b37_xlat), TATSpecCodeTab.Create(1, 4, 2, 1, -1,
      huff_b41_cb, huff_b41_xlat), TATSpecCodeTab.Create(4, 2, 3, 1, -1, huff_b42_cb, huff_b42_xlat),
    TATSpecCodeTab.Create(1, 2, 3, 1, -1, huff_b43_cb, huff_b43_xlat), TATSpecCodeTab.Create(4, 2, 4, 1, 66,
      nil, nil), TATSpecCodeTab.Create(1, 1, 3, 0, 32, nil, nil), TATSpecCodeTab.Create(1, 2, 4, 0, 12, nil,
      nil), TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_b47_cb, huff_b47_xlat), TATSpecCodeTab.Create(2, 4, 2, 1,
      42, nil, nil), TATSpecCodeTab.Create(1, 2, 3, 1, -1, huff_b52_cb, huff_b52_xlat), TATSpecCodeTab.Create(4,
      1, 3, 1, -1, huff_b53_cb, huff_b53_xlat), TATSpecCodeTab.Create(1, 1, 3, 0, 17, nil, nil),
    TATSpecCodeTab.Create(1, 1, 3, 0, 39, nil, nil), TATSpecCodeTab.Create(1, 1, 5, 1, -1, huff_b56_cb,
      huff_b56_xlat), TATSpecCodeTab.Create(2, 1, 6, 1, 62, nil, nil), TATSpecCodeTab.Create(1, 4, 2, 1, 28,
      nil, nil), TATSpecCodeTab.Create(1, 4, 2, 0, -1, huff_b62_cb, huff_b62_xlat), TATSpecCodeTab.Create(1, 1,
      3, 1, -1, huff_b63_cb, huff_b63_xlat), TATSpecCodeTab.Create(1, 1, 3, 0, -1, huff_b64_cb, huff_b64_xlat),
    TATSpecCodeTab.Create(4, 2, 4, 1, -1, huff_b65_cb, huff_b65_xlat), TATSpecCodeTab.Create(1, 2, 4, 0, -1,
      huff_b66_cb, huff_b66_xlat), TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_b67_cb, huff_b67_xlat),
    TATSpecCodeTab.Create(1, 4, 2, 1, -1, huff_b71_cb, huff_b71_xlat), TATSpecCodeTab.Create(4, 4, 2, 0, 78,
      nil, nil), TATSpecCodeTab.Create(4, 4, 2, 0, -1, huff_b73_cb, huff_b73_xlat), TATSpecCodeTab.Create(1, 1,
      4, 1, -1, huff_b74_cb, huff_b74_xlat), TATSpecCodeTab.Create(1, 2, 4, 1, -1, huff_b75_cb, huff_b75_xlat),
    TATSpecCodeTab.Create(1, 1, 5, 1, 47, nil, nil), TATSpecCodeTab.Create(1, 1, 6, 1, -1, huff_b77_cb,
      huff_b77_xlat));
end;

procedure Init_atrac3p_wl_huff_code1;
const
  Values: array[0..2] of Integer = (
    0, 2, 3);
begin
  atrac3p_wl_huff_code1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_bits1;
const
  Values: array[0..2] of Integer = (
    1, 2, 2);
begin
  atrac3p_wl_huff_bits1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_xlat1;
const
  Values: array[0..2] of Integer = (
    0, 1, 7);
begin
  atrac3p_wl_huff_xlat1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_code2;
const
  Values: array[0..4] of Integer = (
    0, 4, 5, 6, 7);
begin
  atrac3p_wl_huff_code2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_bits2;
const
  Values: array[0..4] of Integer = (
    1, 3, 3, 3, 3);
begin
  atrac3p_wl_huff_bits2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_xlat2;
const
  Values: array[0..4] of Integer = (
    0, 1, 2, 6, 7);
begin
  atrac3p_wl_huff_xlat2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_code3;
const
  Values: array[0..7] of Integer = (
    0, 4, 12, 30, 31, 13, 14, 5);
begin
  atrac3p_wl_huff_code3 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_bits3;
const
  Values: array[0..7] of Integer = (
    1, 3, 4, 5, 5, 4, 4, 3);
begin
  atrac3p_wl_huff_bits3 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_code4;
const
  Values: array[0..7] of Integer = (
    0, 4, 12, 13, 30, 31, 14, 5);
begin
  atrac3p_wl_huff_code4 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_huff_bits4;
const
  Values: array[0..7] of Integer = (
    1, 3, 4, 4, 5, 5, 4, 3);
begin
  atrac3p_wl_huff_bits4 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_code1;
const
  Values: array[0..63] of Integer = (
    0, 2, 3, 4, 5, 12, 13, 224, 225, 226, 227, 228, 229, 230, 462, 463, 464, 465, 466, 467, 468,
    469, 470, 471, 472, 473, 474, 475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487,
    488, 489, 490, 491, 492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 506,
    507, 508, 509, 510, 511);
begin
  atrac3p_sf_huff_code1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_bits1;
const
  Values: array[0..63] of Integer = (
    2, 3, 3, 3, 3, 4, 4, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9);
begin
  atrac3p_sf_huff_bits1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_xlat1;
const
  Values: array[0..63] of Integer = (
    0, 1, 61, 62, 63, 2, 60, 3, 4, 5, 6, 57, 58, 59, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
    43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56);
begin
  atrac3p_sf_huff_xlat1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_xlat2;
const
  Values: array[0..63] of Integer = (
    0, 1, 2, 62, 63, 3, 61, 4, 5, 6, 57, 58, 59, 60, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
    43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56);
begin
  atrac3p_sf_huff_xlat2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_code2;
const
  Values: array[0..63] of Integer = (
    0, 4, 24, 25, 112, 458, 459, 460, 461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 471, 472,
    473, 474, 475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490, 491,
    492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 510,
    511, 228, 113, 26, 27, 5);
begin
  atrac3p_sf_huff_code2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_bits2;
const
  Values: array[0..63] of Integer = (
    1, 3, 5, 5, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 8, 7, 5, 5, 3);
begin
  atrac3p_sf_huff_bits2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_code3;
const
  Values: array[0..63] of Integer = (
    0, 2, 3, 24, 25, 112, 460, 461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 471, 472, 473, 474,
    475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490, 491, 492, 493,
    494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 510, 511, 113,
    114, 26, 27, 4, 5);
begin
  atrac3p_sf_huff_code3 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_bits3;
const
  Values: array[0..63] of Integer = (
    2, 3, 3, 5, 5, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7, 5, 5, 3, 3);
begin
  atrac3p_sf_huff_bits3 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_code4;
const
  Values: array[0..15] of Integer = (
    0, 2, 3, 4, 5, 12, 13, 56, 57, 58, 59, 60, 0, 61, 62, 63);
begin
  atrac3p_sf_huff_code4 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_bits4;
const
  Values: array[0..15] of Integer = (
    2, 3, 3, 3, 3, 4, 4, 6, 6, 6, 6, 6, 0, 6, 6, 6);
begin
  atrac3p_sf_huff_bits4 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_xlat4;
const
  Values: array[0..15] of Integer = (
    0, 1, 13, 14, 15, 2, 12, 3, 4, 5, 6, 7, 8, 9, 10, 11);
begin
  atrac3p_sf_huff_xlat4 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_xlat5;
const
  Values: array[0..15] of Integer = (
    0, 1, 2, 14, 15, 3, 13, 4, 5, 6, 7, 9, 8, 10, 11, 12);
begin
  atrac3p_sf_huff_xlat5 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_code5;
const
  Values: array[0..15] of Integer = (
    0, 4, 12, 28, 120, 121, 122, 123, 0, 124, 125, 126, 127, 29, 13, 5);
begin
  atrac3p_sf_huff_code5 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_bits5;
const
  Values: array[0..15] of Integer = (
    1, 3, 4, 5, 7, 7, 7, 7, 0, 7, 7, 7, 7, 5, 4, 3);
begin
  atrac3p_sf_huff_bits5 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_code6;
const
  Values: array[0..15] of Integer = (
    0, 2, 3, 12, 28, 60, 124, 125, 0, 126, 127, 61, 29, 13, 4, 5);
begin
  atrac3p_sf_huff_code6 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_sf_huff_bits6;
const
  Values: array[0..15] of Integer = (
    2, 3, 3, 4, 5, 6, 7, 7, 0, 7, 7, 6, 5, 4, 3, 3);
begin
  atrac3p_sf_huff_bits6 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_code1;
const
  Values: array[0..3] of Integer = (
    0, 2, 6, 7);
begin
  atrac3p_ct_huff_code1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_bits1;
const
  Values: array[0..3] of Integer = (
    1, 2, 3, 3);
begin
  atrac3p_ct_huff_bits1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_code2;
const
  Values: array[0..7] of Integer = (
    0, 2, 3, 4, 5, 6, 14, 15);
begin
  atrac3p_ct_huff_code2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_bits2;
const
  Values: array[0..7] of Integer = (
    2, 3, 3, 3, 3, 3, 4, 4);
begin
  atrac3p_ct_huff_bits2 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_xlat1;
const
  Values: array[0..7] of Integer = (
    0, 1, 2, 3, 6, 7, 4, 5);
begin
  atrac3p_ct_huff_xlat1 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_code3;
const
  Values: array[0..7] of Integer = (
    0, 4, 10, 11, 12, 13, 14, 15);
begin
  atrac3p_ct_huff_code3 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_ct_huff_bits3;
const
  Values: array[0..7] of Integer = (
    1, 3, 4, 4, 4, 4, 4, 4);
begin
  atrac3p_ct_huff_bits3 := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_weights;
const
  Values: array[0..31] of Integer = (
    5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  RowValues2: array[0..31] of Integer = (
    5, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  RowValues3: array[0..31] of Integer = (
    6, 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 3, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0);
  RowValues4: array[0..31] of Integer = (
    5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  RowValues5: array[0..31] of Integer = (
    5, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  RowValues6: array[0..31] of Integer = (
    6, 5, 5, 5, 5, 5, 5, 5, 3, 3, 3, 3, 2, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
begin
  atrac3p_wl_weights := TArray<TArray<Integer>>.Create(CopyIntegerTable(Values), CopyIntegerTable(RowValues2), CopyIntegerTable(RowValues3),
    CopyIntegerTable(RowValues4), CopyIntegerTable(RowValues5), CopyIntegerTable(RowValues6));
end;

procedure Init_atrac3p_sf_weights;
const
  Values: array[0..31] of Integer = (
    0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14,
    14, 15, 15);
  RowValues2: array[0..31] of Integer = (
    0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10);
begin
  atrac3p_sf_weights := TArray<TArray<Integer>>.Create(CopyIntegerTable(Values), CopyIntegerTable(RowValues2));
end;

procedure Init_atrac3p_qu_num_to_seg;
const
  Values: array[0..31] of Integer = (
    0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 9, 9);
begin
  atrac3p_qu_num_to_seg := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_qu_to_subband;
const
  Values: array[0..31] of Integer = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 11, 12, 13,
    14, 15);
begin
  atrac3p_qu_to_subband := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_subband_to_num_powgrps;
const
  Values: array[0..15] of Integer = (
    1, 2, 2, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5);
begin
  atrac3p_subband_to_num_powgrps := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_wl_shapes;
const
  Values: array[0..8] of Integer = (
    0, 0, 0, 0, 0, 0, 0, -2, -1);
  RowValues2: array[0..8] of Integer = (
    0, 0, 0, 0, 0, 0, 0, -5, -1);
  RowValues3: array[0..8] of Integer = (
    0, 0, 0, -7, 0, 0, 0, 0, 0);
  RowValues4: array[0..8] of Integer = (
    0, 0, 0, 0, 0, -7, 0, 0, 0);
  RowValues5: array[0..8] of Integer = (
    0, 0, 0, 0, 0, 0, -5, 0, 0);
  RowValues6: array[0..8] of Integer = (
    0, 0, 0, 0, -5, 0, 0, 0, 0);
  RowValues7: array[0..8] of Integer = (
    -7, -7, 0, 0, 0, 0, 0, 0, 0);
  RowValues8: array[0..8] of Integer = (
    0, -7, 0, 0, 0, 0, 0, 0, 0);
  RowValues9: array[0..8] of Integer = (
    -2, -2, -5, 0, 0, 0, 0, 0, 0);
  RowValues10: array[0..8] of Integer = (
    0, 0, 0, -2, -5, 0, 0, 0, 0);
  RowValues11: array[0..8] of Integer = (
    0, 0, 0, 0, 0, -2, -5, 0, 0);
  RowValues12: array[0..8] of Integer = (
    0, 0, 0, -5, 0, 0, 0, 0, 0);
  RowValues13: array[0..8] of Integer = (
    0, -2, -7, -2, 0, 0, 0, 0, 0);
  RowValues14: array[0..8] of Integer = (
    0, 0, 0, 0, -2, -5, 0, 0, 0);
  RowValues15: array[0..8] of Integer = (
    0, 0, 0, -5, -5, 0, 0, 0, 0);
  RowValues16: array[0..8] of Integer = (
    0, 0, 0, -5, -2, 0, 0, 0, 0);
  RowValues17: array[0..8] of Integer = (
    -1, -5, -3, -2, -1, -1, 0, 0, 0);
  RowValues18: array[0..8] of Integer = (
    -2, -5, -3, -3, -2, -1, -1, 0, 0);
  RowValues19: array[0..8] of Integer = (
    0, -1, -1, -1, 0, 0, 0, 0, 0);
  RowValues20: array[0..8] of Integer = (
    -1, -3, 0, 0, 0, 0, 0, 0, 0);
  RowValues21: array[0..8] of Integer = (
    -1, -2, 0, 0, 0, 0, 0, 0, 0);
  RowValues22: array[0..8] of Integer = (
    -1, -3, -1, 0, 0, 0, 0, 1, 1);
  RowValues23: array[0..8] of Integer = (
    -1, -5, -3, -3, -2, -1, 0, 0, 0);
  RowValues24: array[0..8] of Integer = (
    -1, -1, -4, -2, -2, -1, -1, 0, 0);
  RowValues25: array[0..8] of Integer = (
    -1, -1, -3, -2, -3, -1, -1, -1, 0);
  RowValues26: array[0..8] of Integer = (
    -1, -4, -2, -3, -1, 0, 0, 0, 0);
  RowValues27: array[0..8] of Integer = (
    0, -1, -2, -2, -1, -1, 0, 0, 0);
  RowValues28: array[0..8] of Integer = (
    0, -2, -1, 0, 0, 0, 0, 0, 0);
  RowValues29: array[0..8] of Integer = (
    -1, -1, 0, 0, 0, 0, 0, 0, 0);
  RowValues30: array[0..8] of Integer = (
    -1, -1, -3, -2, -2, -1, -1, -1, 0);
  RowValues31: array[0..8] of Integer = (
    0, 0, 0, 0, 0, 0, 0, 0, 0);
  RowValues32: array[0..8] of Integer = (
    0, -1, -3, -2, -2, -1, -1, -1, 0);
  RowValues33: array[0..8] of Integer = (
    -1, -2, 0, 1, 1, 1, 1, 1, 1);
  RowValues34: array[0..8] of Integer = (
    0, -1, 1, 1, 1, 1, 1, 1, 1);
  RowValues35: array[0..8] of Integer = (
    0, -2, 1, 1, 1, 1, 1, 1, 1);
  RowValues36: array[0..8] of Integer = (
    0, -2, 0, 1, 1, 1, 1, 1, 1);
  RowValues37: array[0..8] of Integer = (
    -1, -1, 0, 1, 1, 1, 1, 1, 1);
  RowValues38: array[0..8] of Integer = (
    0, 0, -1, 0, 1, 1, 1, 1, 1);
  RowValues39: array[0..8] of Integer = (
    -1, -1, 1, 1, 1, 1, 1, 1, 1);
  RowValues40: array[0..8] of Integer = (
    0, 0, -1, 1, 1, 1, 1, 1, 1);
  RowValues41: array[0..8] of Integer = (
    0, -1, 0, 1, 1, 1, 1, 1, 1);
  RowValues42: array[0..8] of Integer = (
    -1, -1, -1, 1, 1, 1, 1, 1, 1);
  RowValues43: array[0..8] of Integer = (
    0, 0, 0, 0, 1, 1, 1, 1, 1);
  RowValues44: array[0..8] of Integer = (
    0, 0, 0, 1, 1, 1, 1, 1, 1);
  RowValues45: array[0..8] of Integer = (
    0, -1, -1, 1, 1, 1, 1, 1, 1);
  RowValues46: array[0..8] of Integer = (
    0, 1, 0, 1, 1, 1, 1, 1, 1);
  RowValues47: array[0..8] of Integer = (
    0, -3, -2, 1, 1, 1, 1, 2, 2);
  RowValues48: array[0..8] of Integer = (
    -3, -5, -3, 2, 2, 2, 2, 2, 2);
  RowValues49: array[0..8] of Integer = (
    -1, -2, 0, 2, 2, 2, 2, 2, 2);
  RowValues50: array[0..8] of Integer = (
    -1, -2, 0, 1, 2, 2, 2, 2, 2);
  RowValues51: array[0..8] of Integer = (
    0, -2, 0, 2, 2, 2, 2, 2, 2);
  RowValues52: array[0..8] of Integer = (
    -1, 0, 1, 2, 2, 2, 2, 2, 2);
  RowValues53: array[0..8] of Integer = (
    0, 0, 1, 2, 2, 2, 2, 2, 2);
  RowValues54: array[0..8] of Integer = (
    0, -2, 0, 1, 2, 2, 2, 2, 2);
  RowValues55: array[0..8] of Integer = (
    0, -1, 1, 2, 2, 2, 2, 2, 2);
  RowValues56: array[0..8] of Integer = (
    -1, -1, 0, 2, 2, 2, 2, 2, 2);
  RowValues57: array[0..8] of Integer = (
    -1, -1, 0, 1, 2, 2, 2, 2, 2);
  RowValues58: array[0..8] of Integer = (
    -1, -2, -1, 2, 2, 2, 2, 2, 2);
  RowValues59: array[0..8] of Integer = (
    0, -1, 0, 2, 2, 2, 2, 2, 2);
  RowValues60: array[0..8] of Integer = (
    1, 1, 0, 1, 2, 2, 2, 2, 2);
  RowValues61: array[0..8] of Integer = (
    0, 1, 2, 2, 2, 2, 2, 2, 2);
  RowValues62: array[0..8] of Integer = (
    1, 0, 0, 1, 2, 2, 2, 2, 2);
  RowValues63: array[0..8] of Integer = (
    0, 0, 0, 1, 2, 2, 2, 2, 2);
  RowValues64: array[0..8] of Integer = (
    -1, -1, -1, 1, 2, 2, 2, 2, 2);
  RowValues65: array[0..8] of Integer = (
    0, 1, 2, 3, 3, 3, 3, 3, 3);
  RowValues66: array[0..8] of Integer = (
    1, 1, 2, 3, 3, 3, 3, 3, 3);
  RowValues67: array[0..8] of Integer = (
    -1, 0, 1, 2, 3, 3, 3, 3, 3);
  RowValues68: array[0..8] of Integer = (
    0, 0, 2, 3, 3, 3, 3, 3, 3);
  RowValues69: array[0..8] of Integer = (
    -1, 0, 1, 3, 3, 3, 3, 3, 3);
  RowValues70: array[0..8] of Integer = (
    0, 0, 1, 3, 3, 3, 3, 3, 3);
  RowValues71: array[0..8] of Integer = (
    1, 2, 3, 3, 3, 3, 3, 3, 3);
  RowValues72: array[0..8] of Integer = (
    1, 2, 2, 3, 3, 3, 3, 3, 3);
  RowValues73: array[0..8] of Integer = (
    0, 1, 1, 3, 3, 3, 3, 3, 3);
  RowValues74: array[0..8] of Integer = (
    0, 0, 1, 2, 3, 3, 3, 3, 3);
  RowValues75: array[0..8] of Integer = (
    -1, 1, 2, 3, 3, 3, 3, 3, 3);
  RowValues76: array[0..8] of Integer = (
    -1, 0, 2, 3, 3, 3, 3, 3, 3);
  RowValues77: array[0..8] of Integer = (
    2, 2, 3, 3, 3, 3, 3, 3, 3);
  RowValues78: array[0..8] of Integer = (
    1, 1, 3, 3, 3, 3, 3, 3, 3);
  RowValues79: array[0..8] of Integer = (
    0, 2, 3, 3, 3, 3, 3, 3, 3);
  RowValues80: array[0..8] of Integer = (
    0, 1, 1, 2, 3, 3, 3, 3, 3);
  RowValues81: array[0..8] of Integer = (
    0, 1, 2, 3, 4, 4, 4, 4, 4);
  RowValues82: array[0..8] of Integer = (
    1, 2, 3, 4, 4, 4, 4, 4, 4);
  RowValues83: array[0..8] of Integer = (
    0, 0, 2, 3, 4, 4, 4, 4, 4);
  RowValues84: array[0..8] of Integer = (
    1, 1, 2, 4, 4, 4, 4, 4, 4);
  RowValues85: array[0..8] of Integer = (
    0, 1, 2, 4, 4, 4, 4, 4, 4);
  RowValues86: array[0..8] of Integer = (
    -1, 0, 1, 3, 4, 4, 4, 4, 4);
  RowValues87: array[0..8] of Integer = (
    0, 0, 1, 3, 4, 4, 4, 4, 4);
  RowValues88: array[0..8] of Integer = (
    1, 1, 2, 3, 4, 4, 4, 4, 4);
  RowValues89: array[0..8] of Integer = (
    0, 1, 1, 3, 4, 4, 4, 4, 4);
  RowValues90: array[0..8] of Integer = (
    2, 2, 3, 4, 4, 4, 4, 4, 4);
  RowValues91: array[0..8] of Integer = (
    1, 1, 3, 4, 4, 4, 4, 4, 4);
  RowValues92: array[0..8] of Integer = (
    1, 2, 2, 4, 4, 4, 4, 4, 4);
  RowValues93: array[0..8] of Integer = (
    -1, 0, 2, 3, 4, 4, 4, 4, 4);
  RowValues94: array[0..8] of Integer = (
    0, 1, 3, 4, 4, 4, 4, 4, 4);
  RowValues95: array[0..8] of Integer = (
    1, 2, 2, 3, 4, 4, 4, 4, 4);
  RowValues96: array[0..8] of Integer = (
    0, 2, 3, 4, 4, 4, 4, 4, 4);
  RowValues97: array[0..8] of Integer = (
    1, 2, 3, 4, 5, 5, 5, 5, 5);
  RowValues98: array[0..8] of Integer = (
    0, 1, 2, 3, 4, 5, 5, 5, 5);
  RowValues99: array[0..8] of Integer = (
    0, 1, 2, 3, 5, 5, 5, 5, 5);
  RowValues100: array[0..8] of Integer = (
    1, 1, 3, 4, 5, 5, 5, 5, 5);
  RowValues101: array[0..8] of Integer = (
    1, 1, 2, 4, 5, 5, 5, 5, 5);
  RowValues102: array[0..8] of Integer = (
    1, 2, 2, 4, 5, 5, 5, 5, 5);
  RowValues103: array[0..8] of Integer = (
    1, 1, 2, 3, 5, 5, 5, 5, 5);
  RowValues104: array[0..8] of Integer = (
    2, 2, 3, 4, 5, 5, 5, 5, 5);
  RowValues105: array[0..8] of Integer = (
    0, 1, 2, 4, 5, 5, 5, 5, 5);
  RowValues106: array[0..8] of Integer = (
    2, 2, 3, 5, 5, 5, 5, 5, 5);
  RowValues107: array[0..8] of Integer = (
    1, 2, 3, 5, 5, 5, 5, 5, 5);
  RowValues108: array[0..8] of Integer = (
    0, 1, 3, 4, 5, 5, 5, 5, 5);
  RowValues109: array[0..8] of Integer = (
    1, 2, 2, 3, 5, 5, 5, 5, 5);
  RowValues110: array[0..8] of Integer = (
    2, 3, 4, 5, 5, 5, 5, 5, 5);
  RowValues111: array[0..8] of Integer = (
    0, 2, 3, 4, 5, 5, 5, 5, 5);
  RowValues112: array[0..8] of Integer = (
    1, 1, 1, 3, 4, 5, 5, 5, 5);
  RowValues113: array[0..8] of Integer = (
    1, 2, 3, 4, 5, 5, 5, 6, 6);
  RowValues114: array[0..8] of Integer = (
    1, 2, 3, 4, 5, 6, 6, 6, 6);
  RowValues115: array[0..8] of Integer = (
    2, 3, 4, 5, 6, 6, 6, 6, 6);
  RowValues116: array[0..8] of Integer = (
    1, 2, 3, 4, 6, 6, 6, 6, 6);
  RowValues117: array[0..8] of Integer = (
    2, 2, 3, 4, 5, 5, 5, 6, 6);
  RowValues118: array[0..8] of Integer = (
    1, 2, 3, 4, 5, 5, 6, 6, 6);
  RowValues119: array[0..8] of Integer = (
    2, 2, 3, 4, 6, 6, 6, 6, 6);
  RowValues120: array[0..8] of Integer = (
    2, 2, 3, 4, 5, 6, 6, 6, 6);
  RowValues121: array[0..8] of Integer = (
    2, 2, 4, 5, 6, 6, 6, 6, 6);
  RowValues122: array[0..8] of Integer = (
    2, 2, 3, 5, 6, 6, 6, 6, 6);
  RowValues123: array[0..8] of Integer = (
    1, 2, 3, 5, 6, 6, 6, 6, 6);
  RowValues124: array[0..8] of Integer = (
    2, 3, 3, 5, 6, 6, 6, 6, 6);
  RowValues125: array[0..8] of Integer = (
    1, 2, 4, 5, 6, 6, 6, 6, 6);
  RowValues126: array[0..8] of Integer = (
    2, 2, 3, 4, 5, 5, 6, 6, 6);
  RowValues127: array[0..8] of Integer = (
    2, 3, 3, 4, 6, 6, 6, 6, 6);
  RowValues128: array[0..8] of Integer = (
    1, 3, 4, 5, 6, 6, 6, 6, 6);
begin
  atrac3p_wl_shapes :=
    TArray<TArray<TArray<Integer>>>.Create(TArray<TArray<Integer>>.Create(CopyIntegerTable(Values), CopyIntegerTable(RowValues2), CopyIntegerTable(RowValues3), CopyIntegerTable(RowValues4), CopyIntegerTable(RowValues5), CopyIntegerTable(RowValues6), CopyIntegerTable(RowValues7), CopyIntegerTable(RowValues8), CopyIntegerTable(RowValues9), CopyIntegerTable(RowValues10), CopyIntegerTable(RowValues11), CopyIntegerTable(RowValues12), CopyIntegerTable(RowValues13), CopyIntegerTable(RowValues14), CopyIntegerTable(RowValues15), CopyIntegerTable(RowValues16)),
    TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues17),
      CopyIntegerTable(RowValues18), CopyIntegerTable(RowValues19), CopyIntegerTable(RowValues20), CopyIntegerTable(RowValues21), CopyIntegerTable(RowValues22), CopyIntegerTable(RowValues23), CopyIntegerTable(RowValues24), CopyIntegerTable(RowValues25), CopyIntegerTable(RowValues26), CopyIntegerTable(RowValues27), CopyIntegerTable(RowValues28),
      CopyIntegerTable(RowValues29), CopyIntegerTable(RowValues30), CopyIntegerTable(RowValues31), CopyIntegerTable(RowValues32)), TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues33),
      CopyIntegerTable(RowValues34), CopyIntegerTable(RowValues35),
      CopyIntegerTable(RowValues36), CopyIntegerTable(RowValues37),
      CopyIntegerTable(RowValues38), CopyIntegerTable(RowValues39),
      CopyIntegerTable(RowValues40), CopyIntegerTable(RowValues41),
      CopyIntegerTable(RowValues42), CopyIntegerTable(RowValues43),
      CopyIntegerTable(RowValues44), CopyIntegerTable(RowValues45),
      CopyIntegerTable(RowValues46), CopyIntegerTable(RowValues47),
      CopyIntegerTable(RowValues48)),
    TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues49),
      CopyIntegerTable(RowValues50), CopyIntegerTable(RowValues51),
      CopyIntegerTable(RowValues52), CopyIntegerTable(RowValues53),
      CopyIntegerTable(RowValues54), CopyIntegerTable(RowValues55),
      CopyIntegerTable(RowValues56), CopyIntegerTable(RowValues57),
      CopyIntegerTable(RowValues58), CopyIntegerTable(RowValues59),
      CopyIntegerTable(RowValues60), CopyIntegerTable(RowValues61),
      CopyIntegerTable(RowValues62), CopyIntegerTable(RowValues63),
      CopyIntegerTable(RowValues64)),
    TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues65),
      CopyIntegerTable(RowValues66), CopyIntegerTable(RowValues67),
      CopyIntegerTable(RowValues68), CopyIntegerTable(RowValues69),
      CopyIntegerTable(RowValues70), CopyIntegerTable(RowValues71),
      CopyIntegerTable(RowValues72), CopyIntegerTable(RowValues73),
      CopyIntegerTable(RowValues74), CopyIntegerTable(RowValues75),
      CopyIntegerTable(RowValues76), CopyIntegerTable(RowValues77),
      CopyIntegerTable(RowValues78), CopyIntegerTable(RowValues79),
      CopyIntegerTable(RowValues80)),
    TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues81),
      CopyIntegerTable(RowValues82), CopyIntegerTable(RowValues83),
      CopyIntegerTable(RowValues84), CopyIntegerTable(RowValues85),
      CopyIntegerTable(RowValues86), CopyIntegerTable(RowValues87),
      CopyIntegerTable(RowValues88), CopyIntegerTable(RowValues89),
      CopyIntegerTable(RowValues90), CopyIntegerTable(RowValues91),
      CopyIntegerTable(RowValues92), CopyIntegerTable(RowValues93),
      CopyIntegerTable(RowValues94), CopyIntegerTable(RowValues95),
      CopyIntegerTable(RowValues96)),
    TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues97),
      CopyIntegerTable(RowValues98), CopyIntegerTable(RowValues99),
      CopyIntegerTable(RowValues100), CopyIntegerTable(RowValues101),
      CopyIntegerTable(RowValues102), CopyIntegerTable(RowValues103),
      CopyIntegerTable(RowValues104), CopyIntegerTable(RowValues105),
      CopyIntegerTable(RowValues106), CopyIntegerTable(RowValues107),
      CopyIntegerTable(RowValues108), CopyIntegerTable(RowValues109),
      CopyIntegerTable(RowValues110), CopyIntegerTable(RowValues111),
      CopyIntegerTable(RowValues112)),
    TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues113),
      CopyIntegerTable(RowValues114), CopyIntegerTable(RowValues115),
      CopyIntegerTable(RowValues116), CopyIntegerTable(RowValues117),
      CopyIntegerTable(RowValues118), CopyIntegerTable(RowValues119),
      CopyIntegerTable(RowValues120), CopyIntegerTable(RowValues121),
      CopyIntegerTable(RowValues122), CopyIntegerTable(RowValues123),
      CopyIntegerTable(RowValues124), CopyIntegerTable(RowValues125),
      CopyIntegerTable(RowValues126), CopyIntegerTable(RowValues127),
      CopyIntegerTable(RowValues128)));
end;

procedure Init_atrac3p_sf_shapes;
const
  Values: array[0..8] of Integer = (
    -3, -2, -1, 0, 3, 5, 6, 8, 40);
  RowValues2: array[0..8] of Integer = (
    -3, -2, 0, 1, 7, 9, 11, 13, 20);
  RowValues3: array[0..8] of Integer = (
    -1, 0, 0, 1, 6, 8, 10, 13, 41);
  RowValues4: array[0..8] of Integer = (
    0, 0, 0, 2, 5, 5, 6, 8, 14);
  RowValues5: array[0..8] of Integer = (
    0, 0, 0, 2, 6, 7, 8, 11, 47);
  RowValues6: array[0..8] of Integer = (
    0, 0, 1, 2, 5, 7, 8, 10, 32);
  RowValues7: array[0..8] of Integer = (
    0, 0, 1, 3, 8, 10, 12, 14, 47);
  RowValues8: array[0..8] of Integer = (
    0, 0, 2, 4, 9, 10, 12, 14, 40);
  RowValues9: array[0..8] of Integer = (
    0, 0, 3, 5, 9, 10, 12, 14, 22);
  RowValues10: array[0..8] of Integer = (
    0, 1, 3, 5, 10, 14, 18, 22, 31);
  RowValues11: array[0..8] of Integer = (
    0, 2, 5, 6, 10, 10, 10, 12, 46);
  RowValues12: array[0..8] of Integer = (
    0, 2, 5, 7, 12, 14, 15, 18, 44);
  RowValues13: array[0..8] of Integer = (
    1, 1, 4, 5, 7, 7, 8, 9, 15);
  RowValues14: array[0..8] of Integer = (
    1, 2, 2, 2, 4, 5, 7, 9, 26);
  RowValues15: array[0..8] of Integer = (
    1, 2, 2, 3, 6, 7, 7, 8, 47);
  RowValues16: array[0..8] of Integer = (
    1, 2, 2, 3, 6, 8, 10, 13, 22);
  RowValues17: array[0..8] of Integer = (
    1, 3, 4, 7, 13, 17, 21, 24, 41);
  RowValues18: array[0..8] of Integer = (
    1, 4, 0, 4, 10, 12, 13, 14, 17);
  RowValues19: array[0..8] of Integer = (
    2, 3, 3, 3, 6, 8, 10, 13, 48);
  RowValues20: array[0..8] of Integer = (
    2, 3, 3, 4, 9, 12, 14, 17, 47);
  RowValues21: array[0..8] of Integer = (
    2, 3, 3, 5, 10, 12, 14, 17, 25);
  RowValues22: array[0..8] of Integer = (
    2, 3, 5, 7, 8, 9, 9, 9, 13);
  RowValues23: array[0..8] of Integer = (
    2, 3, 5, 9, 16, 21, 25, 28, 33);
  RowValues24: array[0..8] of Integer = (
    2, 4, 5, 8, 12, 14, 17, 19, 26);
  RowValues25: array[0..8] of Integer = (
    2, 4, 6, 8, 12, 13, 13, 15, 20);
  RowValues26: array[0..8] of Integer = (
    2, 4, 7, 12, 20, 26, 30, 32, 35);
  RowValues27: array[0..8] of Integer = (
    3, 3, 5, 6, 12, 14, 16, 19, 34);
  RowValues28: array[0..8] of Integer = (
    3, 4, 4, 5, 7, 9, 10, 11, 48);
  RowValues29: array[0..8] of Integer = (
    3, 4, 5, 6, 8, 9, 10, 11, 16);
  RowValues30: array[0..8] of Integer = (
    3, 5, 5, 5, 7, 9, 10, 13, 35);
  RowValues31: array[0..8] of Integer = (
    3, 5, 5, 7, 10, 12, 13, 15, 49);
  RowValues32: array[0..8] of Integer = (
    3, 5, 7, 7, 8, 7, 9, 12, 21);
  RowValues33: array[0..8] of Integer = (
    3, 5, 7, 8, 12, 14, 15, 15, 24);
  RowValues34: array[0..8] of Integer = (
    3, 5, 7, 10, 16, 21, 24, 27, 44);
  RowValues35: array[0..8] of Integer = (
    3, 5, 8, 14, 21, 26, 28, 29, 42);
  RowValues36: array[0..8] of Integer = (
    3, 6, 10, 13, 18, 19, 20, 22, 27);
  RowValues37: array[0..8] of Integer = (
    3, 6, 11, 16, 24, 27, 28, 29, 31);
  RowValues38: array[0..8] of Integer = (
    4, 5, 4, 3, 4, 6, 8, 11, 18);
  RowValues39: array[0..8] of Integer = (
    4, 6, 5, 6, 9, 10, 12, 14, 20);
  RowValues40: array[0..8] of Integer = (
    4, 6, 7, 6, 6, 6, 7, 8, 46);
  RowValues41: array[0..8] of Integer = (
    4, 6, 7, 9, 13, 16, 18, 20, 48);
  RowValues42: array[0..8] of Integer = (
    4, 6, 7, 9, 14, 17, 20, 23, 31);
  RowValues43: array[0..8] of Integer = (
    4, 6, 9, 11, 14, 15, 15, 17, 21);
  RowValues44: array[0..8] of Integer = (
    4, 8, 13, 20, 27, 32, 35, 36, 38);
  RowValues45: array[0..8] of Integer = (
    5, 6, 6, 4, 5, 6, 7, 6, 6);
  RowValues46: array[0..8] of Integer = (
    5, 7, 7, 8, 9, 9, 10, 12, 49);
  RowValues47: array[0..8] of Integer = (
    5, 8, 9, 9, 10, 11, 12, 13, 42);
  RowValues48: array[0..8] of Integer = (
    5, 8, 10, 12, 15, 16, 17, 19, 42);
  RowValues49: array[0..8] of Integer = (
    5, 8, 12, 17, 26, 31, 32, 33, 44);
  RowValues50: array[0..8] of Integer = (
    5, 9, 13, 16, 20, 22, 23, 23, 35);
  RowValues51: array[0..8] of Integer = (
    6, 8, 8, 7, 6, 5, 6, 8, 15);
  RowValues52: array[0..8] of Integer = (
    6, 8, 8, 8, 9, 10, 12, 16, 24);
  RowValues53: array[0..8] of Integer = (
    6, 8, 8, 9, 10, 10, 11, 11, 13);
  RowValues54: array[0..8] of Integer = (
    6, 8, 10, 13, 19, 21, 24, 26, 32);
  RowValues55: array[0..8] of Integer = (
    6, 9, 10, 11, 13, 13, 14, 16, 49);
  RowValues56: array[0..8] of Integer = (
    7, 9, 9, 10, 13, 14, 16, 19, 27);
  RowValues57: array[0..8] of Integer = (
    7, 10, 12, 13, 16, 16, 17, 17, 27);
  RowValues58: array[0..8] of Integer = (
    7, 10, 12, 14, 17, 19, 20, 22, 48);
  RowValues59: array[0..8] of Integer = (
    8, 9, 10, 9, 10, 11, 11, 11, 19);
  RowValues60: array[0..8] of Integer = (
    8, 11, 12, 12, 13, 13, 13, 13, 17);
  RowValues61: array[0..8] of Integer = (
    8, 11, 13, 14, 16, 17, 19, 20, 27);
  RowValues62: array[0..8] of Integer = (
    8, 12, 17, 22, 26, 28, 29, 30, 33);
  RowValues63: array[0..8] of Integer = (
    10, 14, 16, 19, 21, 22, 22, 24, 28);
  RowValues64: array[0..8] of Integer = (
    10, 15, 17, 18, 21, 22, 23, 25, 43);
begin
  atrac3p_sf_shapes := TArray<TArray<Integer>>.Create(CopyIntegerTable(Values),
    CopyIntegerTable(RowValues2), CopyIntegerTable(RowValues3), CopyIntegerTable(RowValues4), CopyIntegerTable(RowValues5), CopyIntegerTable(RowValues6), CopyIntegerTable(RowValues7), CopyIntegerTable(RowValues8), CopyIntegerTable(RowValues9), CopyIntegerTable(RowValues10), CopyIntegerTable(RowValues11), CopyIntegerTable(RowValues12), CopyIntegerTable(RowValues13), CopyIntegerTable(RowValues14), CopyIntegerTable(RowValues15), CopyIntegerTable(RowValues16), CopyIntegerTable(RowValues17), CopyIntegerTable(RowValues18), CopyIntegerTable(RowValues19), CopyIntegerTable(RowValues20),
    CopyIntegerTable(RowValues21), CopyIntegerTable(RowValues22), CopyIntegerTable(RowValues23), CopyIntegerTable(RowValues24), CopyIntegerTable(RowValues25), CopyIntegerTable(RowValues26), CopyIntegerTable(RowValues27), CopyIntegerTable(RowValues28), CopyIntegerTable(RowValues29), CopyIntegerTable(RowValues30), CopyIntegerTable(RowValues31),
    CopyIntegerTable(RowValues32), CopyIntegerTable(RowValues33), CopyIntegerTable(RowValues34), CopyIntegerTable(RowValues35), CopyIntegerTable(RowValues36), CopyIntegerTable(RowValues37), CopyIntegerTable(RowValues38), CopyIntegerTable(RowValues39), CopyIntegerTable(RowValues40), CopyIntegerTable(RowValues41), CopyIntegerTable(RowValues42),
    CopyIntegerTable(RowValues43), CopyIntegerTable(RowValues44), CopyIntegerTable(RowValues45), CopyIntegerTable(RowValues46), CopyIntegerTable(RowValues47), CopyIntegerTable(RowValues48), CopyIntegerTable(RowValues49), CopyIntegerTable(RowValues50), CopyIntegerTable(RowValues51), CopyIntegerTable(RowValues52), CopyIntegerTable(RowValues53),
    CopyIntegerTable(RowValues54), CopyIntegerTable(RowValues55), CopyIntegerTable(RowValues56), CopyIntegerTable(RowValues57), CopyIntegerTable(RowValues58), CopyIntegerTable(RowValues59), CopyIntegerTable(RowValues60),
    CopyIntegerTable(RowValues61), CopyIntegerTable(RowValues62), CopyIntegerTable(RowValues63), CopyIntegerTable(RowValues64));
end;

procedure Init_atrac3p_ct_restricted_to_full;
const
  Values: array[0..3] of Integer = (
    0, 5, 4, 1);
  RowValues2: array[0..3] of Integer = (
    0, 1, 2, 3);
  RowValues3: array[0..3] of Integer = (
    3, 0, 4, 2);
  RowValues4: array[0..3] of Integer = (
    4, 0, 1, 2);
  RowValues5: array[0..3] of Integer = (
    1, 0, 4, 3);
  RowValues6: array[0..3] of Integer = (
    3, 0, 2, 1);
  RowValues7: array[0..3] of Integer = (
    0, 3, 1, 2);
  RowValues8: array[0..3] of Integer = (
    4, 0, 1, 2);
  RowValues9: array[0..3] of Integer = (
    0, 3, 2, 1);
  RowValues10: array[0..3] of Integer = (
    0, 1, 2, 3);
  RowValues11: array[0..3] of Integer = (
    0, 1, 2, 4);
  RowValues12: array[0..3] of Integer = (
    0, 1, 2, 3);
  RowValues13: array[0..3] of Integer = (
    1, 4, 2, 0);
  RowValues14: array[0..3] of Integer = (
    0, 1, 2, 3);
begin
  atrac3p_ct_restricted_to_full :=
    TArray<TArray<TArray<Integer>>>.Create(TArray<TArray<Integer>>.Create(CopyIntegerTable(Values),
      CopyIntegerTable(RowValues2), CopyIntegerTable(RowValues3), CopyIntegerTable(RowValues4), CopyIntegerTable(RowValues5), CopyIntegerTable(RowValues6), CopyIntegerTable(RowValues7)), TArray<TArray<Integer>>.Create(CopyIntegerTable(RowValues8), CopyIntegerTable(RowValues9), CopyIntegerTable(RowValues10), CopyIntegerTable(RowValues11), CopyIntegerTable(RowValues12), CopyIntegerTable(RowValues13), CopyIntegerTable(RowValues14)));
end;

procedure Init_atrac3p_huff_gain_npoints1_cb;
const
  Values: array[0..8] of Integer = (
    1, 7, 1, 1, 1, 1, 1, 1, 2);
begin
  atrac3p_huff_gain_npoints1_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_npoints2_xlat;
const
  Values: array[0..7] of Integer = (
    0, 1, 7, 2, 6, 3, 4, 5);
begin
  atrac3p_huff_gain_npoints2_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev1_cb;
const
  Values: array[0..8] of Integer = (
    1, 7, 1, 0, 2, 2, 1, 2, 8);
begin
  atrac3p_huff_gain_lev1_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev1_xlat;
const
  Values: array[0..15] of Integer = (
    7, 5, 8, 6, 9, 4, 10, 11, 0, 1, 2, 3, 12, 13, 14, 15);
begin
  atrac3p_huff_gain_lev1_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev2_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 1, 1, 1, 1, 0, 2, 0, 8);
begin
  atrac3p_huff_gain_lev2_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev2_xlat;
const
  Values: array[0..14] of Integer = (
    15, 14, 1, 13, 2, 3, 12, 4, 5, 6, 7, 8, 9, 10, 11);
begin
  atrac3p_huff_gain_lev2_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev3_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 0, 3, 1, 1, 0, 2, 0, 8);
begin
  atrac3p_huff_gain_lev3_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev3_xlat;
const
  Values: array[0..15] of Integer = (
    0, 1, 14, 15, 2, 13, 3, 12, 4, 5, 6, 7, 8, 9, 10, 11);
begin
  atrac3p_huff_gain_lev3_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev4_cb;
const
  Values: array[0..10] of Integer = (
    1, 9, 1, 1, 1, 1, 1, 0, 1, 2, 8);
begin
  atrac3p_huff_gain_lev4_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_lev4_xlat;
const
  Values: array[0..15] of Integer = (
    0, 1, 15, 14, 2, 13, 3, 12, 4, 5, 6, 7, 8, 9, 10, 11);
begin
  atrac3p_huff_gain_lev4_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc1_cb;
const
  Values: array[0..8] of Integer = (
    2, 8, 1, 2, 4, 4, 4, 0, 16);
begin
  atrac3p_huff_gain_loc1_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc1_xlat;
const
  Values: array[0..30] of Integer = (
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31);
begin
  atrac3p_huff_gain_loc1_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc2_cb;
const
  Values: array[0..7] of Integer = (
    3, 8, 5, 3, 2, 3, 2, 16);
begin
  atrac3p_huff_gain_loc2_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc2_xlat;
const
  Values: array[0..30] of Integer = (
    2, 3, 4, 5, 6, 1, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31);
begin
  atrac3p_huff_gain_loc2_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc3_cb;
const
  Values: array[0..6] of Integer = (
    2, 6, 1, 0, 2, 11, 18);
begin
  atrac3p_huff_gain_loc3_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc3_xlat;
const
  Values: array[0..31] of Integer = (
    0, 1, 31, 2, 3, 4, 5, 6, 7, 26, 27, 28, 29, 30, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25);
begin
  atrac3p_huff_gain_loc3_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc4_cb;
const
  Values: array[0..4] of Integer = (
    4, 6, 3, 23, 6);
begin
  atrac3p_huff_gain_loc4_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc4_xlat;
const
  Values: array[0..31] of Integer = (
    0, 28, 29, 1, 2, 3, 4, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 30,
    31, 5, 6, 7, 8, 9, 10);
begin
  atrac3p_huff_gain_loc4_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc5_cb;
const
  Values: array[0..8] of Integer = (
    1, 7, 1, 0, 0, 3, 2, 6, 20);
begin
  atrac3p_huff_gain_loc5_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_gain_loc5_xlat;
const
  Values: array[0..31] of Integer = (
    0, 1, 2, 31, 3, 4, 5, 6, 7, 8, 29, 30, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
    23, 24, 25, 26, 27, 28);
begin
  atrac3p_huff_gain_loc5_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_tonebands_cb;
const
  Values: array[0..7] of Integer = (
    1, 6, 1, 0, 1, 2, 4, 8);
begin
  atrac3p_huff_tonebands_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_numwavs1_cb;
const
  Values: array[0..8] of Integer = (
    1, 7, 1, 1, 1, 1, 1, 1, 2);
begin
  atrac3p_huff_numwavs1_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_numwavs2_cb;
const
  Values: array[0..7] of Integer = (
    1, 6, 1, 1, 1, 1, 0, 4);
begin
  atrac3p_huff_numwavs2_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_numwavs2_xlat;
const
  Values: array[0..7] of Integer = (
    0, 1, 7, 2, 3, 4, 5, 6);
begin
  atrac3p_huff_numwavs2_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_wav_ampsf1_cb;
const
  Values: array[0..6] of Integer = (
    4, 8, 10, 8, 6, 0, 8);
begin
  atrac3p_huff_wav_ampsf1_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_wav_ampsf1_xlat;
const
  Values: array[0..31] of Integer = (
    8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 5, 6, 7, 18, 19, 20, 21, 22, 4, 23, 24, 25, 26, 27, 0, 1,
    2, 3, 28, 29, 30, 31);
begin
  atrac3p_huff_wav_ampsf1_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_wav_ampsf2_cb;
const
  Values: array[0..6] of Integer = (
    4, 8, 11, 5, 6, 6, 4);
begin
  atrac3p_huff_wav_ampsf2_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_wav_ampsf2_xlat;
const
  Values: array[0..31] of Integer = (
    18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 14, 15, 16, 17, 29, 9, 10, 11, 12, 13, 30, 4, 5, 6,
    7, 8, 31, 0, 1, 2, 3);
begin
  atrac3p_huff_wav_ampsf2_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_wav_ampsf3_cb;
const
  Values: array[0..8] of Integer = (
    2, 8, 1, 3, 3, 1, 4, 4, 16);
begin
  atrac3p_huff_wav_ampsf3_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_wav_ampsf3_xlat;
const
  Values: array[0..31] of Integer = (
    0, 1, 2, 31, 3, 29, 30, 4, 5, 6, 27, 28, 7, 24, 25, 26, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 23);
begin
  atrac3p_huff_wav_ampsf3_xlat := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_freq_cb;
const
  Values: array[0..12] of Integer = (
    1, 11, 1, 0, 0, 2, 2, 0, 9, 9, 29, 104, 100);
begin
  atrac3p_huff_freq_cb := CopyIntegerTable(Values);
end;

procedure Init_atrac3p_huff_freq_xlat;
const
  Values: array[0..255] of Integer = (
    0, 1, 255, 2, 254, 3, 4, 5, 6, 7, 8, 251, 252, 253, 9, 10, 11, 12, 246, 247, 248, 249, 250, 13,
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37,
    38, 243, 244, 245, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
    58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81,
    82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 194, 195, 196, 197, 198, 199, 200, 201, 202,
    203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221,
    222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240,
    241, 242, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130,
    131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
    150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168,
    169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187,
    188, 189, 190, 191, 192, 193);
begin
  atrac3p_huff_freq_xlat := CopyIntegerTable(Values);
end;

// Preserve dependencies between the spectral descriptors and their tables.
initialization
  Init_huff_a01_cb;
  Init_huff_a01_xlat;
  Init_huff_a02_cb;
  Init_huff_a02_xlat;
  Init_huff_a03_cb;
  Init_huff_a03_xlat;
  Init_huff_a04_cb;
  Init_huff_a04_xlat;
  Init_huff_a05_cb;
  Init_huff_a05_xlat;
  Init_huff_a06_cb;
  Init_huff_a06_xlat;
  Init_huff_a07_cb;
  Init_huff_a07_xlat;
  Init_huff_a11_cb;
  Init_huff_a11_xlat;
  Init_huff_a12_cb;
  Init_huff_a12_xlat;
  Init_huff_a13_cb;
  Init_huff_a13_xlat;
  Init_huff_a14_cb;
  Init_huff_a14_xlat;
  Init_huff_a15_cb;
  Init_huff_a15_xlat;
  Init_huff_a16_cb;
  Init_huff_a16_xlat;
  Init_huff_a17_cb;
  Init_huff_a17_xlat;
  Init_huff_a21_cb;
  Init_huff_a21_xlat;
  Init_huff_a22_cb;
  Init_huff_a22_xlat;
  Init_huff_a23_cb;
  Init_huff_a23_xlat;
  Init_huff_a24_cb;
  Init_huff_a25_cb;
  Init_huff_a25_xlat;
  Init_huff_a26_cb;
  Init_huff_a26_xlat;
  Init_huff_a27_cb;
  Init_huff_a27_xlat;
  Init_huff_a31_cb;
  Init_huff_a31_xlat;
  Init_huff_a32_cb;
  Init_huff_a32_xlat;
  Init_huff_a33_cb;
  Init_huff_a33_xlat;
  Init_huff_a34_cb;
  Init_huff_a34_xlat;
  Init_huff_a35_cb;
  Init_huff_a35_xlat;
  Init_huff_a36_cb;
  Init_huff_a36_xlat;
  Init_huff_a37_cb;
  Init_huff_a37_xlat;
  Init_huff_a41_cb;
  Init_huff_a41_xlat;
  Init_huff_a42_cb;
  Init_huff_a42_xlat;
  Init_huff_a43_cb;
  Init_huff_a43_xlat;
  Init_huff_a44_cb;
  Init_huff_a44_xlat;
  Init_huff_a45_cb;
  Init_huff_a45_xlat;
  Init_huff_a46_cb;
  Init_huff_a46_xlat;
  Init_huff_a47_cb;
  Init_huff_a47_xlat;
  Init_huff_a51_cb;
  Init_huff_a51_xlat;
  Init_huff_a52_cb;
  Init_huff_a52_xlat;
  Init_huff_a53_xlat;
  Init_huff_a54_cb;
  Init_huff_a54_xlat;
  Init_huff_a55_cb;
  Init_huff_a55_xlat;
  Init_huff_a56_cb;
  Init_huff_a56_xlat;
  Init_huff_a57_cb;
  Init_huff_a57_xlat;
  Init_huff_a61_cb;
  Init_huff_a61_xlat;
  Init_huff_a62_cb;
  Init_huff_a62_xlat;
  Init_huff_a63_cb;
  Init_huff_a63_xlat;
  Init_huff_a64_cb;
  Init_huff_a64_xlat;
  Init_huff_a65_cb;
  Init_huff_a65_xlat;
  Init_huff_a66_cb;
  Init_huff_a66_xlat;
  Init_huff_a67_cb;
  Init_huff_a67_xlat;
  Init_huff_a71_cb;
  Init_huff_a72_cb;
  Init_huff_a72_xlat;
  Init_huff_a73_cb;
  Init_huff_a73_xlat;
  Init_huff_a74_cb;
  Init_huff_a74_xlat;
  Init_huff_a75_cb;
  Init_huff_a75_xlat;
  Init_huff_a76_cb;
  Init_huff_a76_xlat;
  Init_huff_b01_cb;
  Init_huff_b01_xlat;
  Init_huff_b02_cb;
  Init_huff_b02_xlat;
  Init_huff_b03_cb;
  Init_huff_b03_xlat;
  Init_huff_b04_cb;
  Init_huff_b04_xlat;
  Init_huff_b05_cb;
  Init_huff_b05_xlat;
  Init_huff_b07_cb;
  Init_huff_b07_xlat;
  Init_huff_b12_cb;
  Init_huff_b12_xlat;
  Init_huff_b14_cb;
  Init_huff_b14_xlat;
  Init_huff_b16_cb;
  Init_huff_b16_xlat;
  Init_huff_b26_cb;
  Init_huff_b26_xlat;
  Init_huff_b32_cb;
  Init_huff_b32_xlat;
  Init_huff_b33_cb;
  Init_huff_b33_xlat;
  Init_huff_b35_cb;
  Init_huff_b35_xlat;
  Init_huff_b37_cb;
  Init_huff_b37_xlat;
  Init_huff_b41_cb;
  Init_huff_b41_xlat;
  Init_huff_b42_cb;
  Init_huff_b42_xlat;
  Init_huff_b43_cb;
  Init_huff_b43_xlat;
  Init_huff_b47_cb;
  Init_huff_b47_xlat;
  Init_huff_b52_cb;
  Init_huff_b52_xlat;
  Init_huff_b53_cb;
  Init_huff_b53_xlat;
  Init_huff_b56_cb;
  Init_huff_b56_xlat;
  Init_huff_b62_cb;
  Init_huff_b62_xlat;
  Init_huff_b63_cb;
  Init_huff_b63_xlat;
  Init_huff_b64_cb;
  Init_huff_b64_xlat;
  Init_huff_b65_cb;
  Init_huff_b65_xlat;
  Init_huff_b66_cb;
  Init_huff_b66_xlat;
  Init_huff_b67_cb;
  Init_huff_b67_xlat;
  Init_huff_b71_cb;
  Init_huff_b71_xlat;
  Init_huff_b73_cb;
  Init_huff_b73_xlat;
  Init_huff_b74_cb;
  Init_huff_b74_xlat;
  Init_huff_b75_cb;
  Init_huff_b75_xlat;
  Init_huff_b77_cb;
  Init_huff_b77_xlat;
  Init_atrac3p_spectra_tabs;
  Init_atrac3p_wl_huff_code1;
  Init_atrac3p_wl_huff_bits1;
  Init_atrac3p_wl_huff_xlat1;
  Init_atrac3p_wl_huff_code2;
  Init_atrac3p_wl_huff_bits2;
  Init_atrac3p_wl_huff_xlat2;
  Init_atrac3p_wl_huff_code3;
  Init_atrac3p_wl_huff_bits3;
  Init_atrac3p_wl_huff_code4;
  Init_atrac3p_wl_huff_bits4;
  Init_atrac3p_sf_huff_code1;
  Init_atrac3p_sf_huff_bits1;
  Init_atrac3p_sf_huff_xlat1;
  Init_atrac3p_sf_huff_xlat2;
  Init_atrac3p_sf_huff_code2;
  Init_atrac3p_sf_huff_bits2;
  Init_atrac3p_sf_huff_code3;
  Init_atrac3p_sf_huff_bits3;
  Init_atrac3p_sf_huff_code4;
  Init_atrac3p_sf_huff_bits4;
  Init_atrac3p_sf_huff_xlat4;
  Init_atrac3p_sf_huff_xlat5;
  Init_atrac3p_sf_huff_code5;
  Init_atrac3p_sf_huff_bits5;
  Init_atrac3p_sf_huff_code6;
  Init_atrac3p_sf_huff_bits6;
  Init_atrac3p_ct_huff_code1;
  Init_atrac3p_ct_huff_bits1;
  Init_atrac3p_ct_huff_code2;
  Init_atrac3p_ct_huff_bits2;
  Init_atrac3p_ct_huff_xlat1;
  Init_atrac3p_ct_huff_code3;
  Init_atrac3p_ct_huff_bits3;
  Init_atrac3p_wl_weights;
  Init_atrac3p_sf_weights;
  Init_atrac3p_qu_num_to_seg;
  Init_atrac3p_qu_to_subband;
  Init_atrac3p_subband_to_num_powgrps;
  Init_atrac3p_wl_shapes;
  Init_atrac3p_sf_shapes;
  Init_atrac3p_ct_restricted_to_full;
  Init_atrac3p_huff_gain_npoints1_cb;
  Init_atrac3p_huff_gain_npoints2_xlat;
  Init_atrac3p_huff_gain_lev1_cb;
  Init_atrac3p_huff_gain_lev1_xlat;
  Init_atrac3p_huff_gain_lev2_cb;
  Init_atrac3p_huff_gain_lev2_xlat;
  Init_atrac3p_huff_gain_lev3_cb;
  Init_atrac3p_huff_gain_lev3_xlat;
  Init_atrac3p_huff_gain_lev4_cb;
  Init_atrac3p_huff_gain_lev4_xlat;
  Init_atrac3p_huff_gain_loc1_cb;
  Init_atrac3p_huff_gain_loc1_xlat;
  Init_atrac3p_huff_gain_loc2_cb;
  Init_atrac3p_huff_gain_loc2_xlat;
  Init_atrac3p_huff_gain_loc3_cb;
  Init_atrac3p_huff_gain_loc3_xlat;
  Init_atrac3p_huff_gain_loc4_cb;
  Init_atrac3p_huff_gain_loc4_xlat;
  Init_atrac3p_huff_gain_loc5_cb;
  Init_atrac3p_huff_gain_loc5_xlat;
  Init_atrac3p_huff_tonebands_cb;
  Init_atrac3p_huff_numwavs1_cb;
  Init_atrac3p_huff_numwavs2_cb;
  Init_atrac3p_huff_numwavs2_xlat;
  Init_atrac3p_huff_wav_ampsf1_cb;
  Init_atrac3p_huff_wav_ampsf1_xlat;
  Init_atrac3p_huff_wav_ampsf2_cb;
  Init_atrac3p_huff_wav_ampsf2_xlat;
  Init_atrac3p_huff_wav_ampsf3_cb;
  Init_atrac3p_huff_wav_ampsf3_xlat;
  Init_atrac3p_huff_freq_cb;
  Init_atrac3p_huff_freq_xlat;

end.
