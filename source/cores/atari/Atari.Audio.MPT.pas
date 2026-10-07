unit Atari.Audio.MPT;

interface

uses
  System.SysUtils, Atari.Audio.ASAP;

procedure LoadMPTSamples(State: TASAP; const Data: TBytes);

procedure LoadMD1(State: TASAP; const Module, Samples: TBytes; Is15kHz: Boolean);

implementation

const
  MPTPlayer: array[0..2232] of Byte = (
    255, 255, 0, 5, 178, 13, 76, 205, 11, 173, 46, 7, 208, 1, 96, 169,
    0, 141, 28, 14, 238, 29, 14, 173, 23, 14, 205, 187, 13, 144, 80, 206,
    21, 14, 240, 3, 76, 197, 5, 162, 0, 142, 23, 14, 169, 0, 157, 237,
    13, 157, 245, 13, 189, 179, 13, 133, 236, 189, 183, 13, 133, 237, 172, 22,
    14, 177, 236, 200, 201, 255, 240, 7, 201, 254, 208, 15, 76, 42, 12, 177,
    236, 48, 249, 10, 168, 140, 22, 14, 76, 59, 5, 157, 233, 13, 177, 236,
    157, 213, 13, 232, 224, 4, 208, 196, 200, 140, 22, 14, 76, 197, 5, 206,
    21, 14, 16, 87, 173, 188, 13, 141, 21, 14, 162, 3, 222, 245, 13, 16,
    68, 189, 233, 13, 10, 168, 185, 255, 255, 133, 236, 200, 185, 255, 255, 133,
    237, 5, 236, 240, 48, 189, 237, 13, 141, 31, 14, 32, 62, 7, 172, 31,
    14, 200, 152, 157, 237, 13, 189, 241, 13, 157, 245, 13, 224, 2, 208, 21,
    189, 197, 13, 73, 15, 10, 10, 10, 10, 105, 69, 141, 161, 13, 169, 10,
    105, 0, 141, 162, 13, 202, 16, 180, 238, 23, 14, 162, 1, 173, 27, 14,
    201, 2, 240, 2, 162, 3, 173, 27, 14, 201, 2, 208, 5, 236, 25, 14,
    240, 3, 76, 118, 6, 181, 240, 61, 114, 6, 240, 18, 160, 40, 177, 236,
    24, 125, 225, 13, 32, 117, 9, 56, 125, 1, 14, 157, 203, 13, 202, 16,
    213, 169, 3, 141, 15, 210, 165, 241, 41, 16, 240, 15, 172, 226, 13, 185,
    198, 9, 141, 201, 13, 185, 5, 10, 141, 202, 13, 173, 201, 13, 141, 0,
    210, 173, 202, 13, 141, 2, 210, 173, 203, 13, 141, 4, 210, 173, 204, 13,
    141, 6, 210, 173, 193, 13, 162, 255, 172, 27, 14, 192, 1, 208, 5, 174,
    25, 14, 240, 3, 141, 1, 210, 173, 194, 13, 224, 1, 240, 3, 141, 3,
    210, 192, 2, 240, 20, 173, 195, 13, 224, 2, 240, 3, 141, 5, 210, 173,
    196, 13, 224, 3, 240, 3, 141, 7, 210, 165, 240, 5, 241, 5, 242, 5,
    243, 13, 28, 14, 141, 8, 210, 96, 4, 2, 0, 0, 189, 217, 13, 133,
    236, 189, 221, 13, 133, 237, 5, 236, 208, 8, 157, 193, 13, 149, 240, 76,
    248, 5, 180, 244, 192, 32, 240, 66, 177, 236, 56, 253, 197, 13, 44, 58,
    7, 240, 2, 41, 240, 157, 193, 13, 200, 177, 236, 141, 30, 14, 200, 148,
    244, 41, 7, 240, 60, 168, 185, 126, 9, 141, 203, 6, 185, 133, 9, 141,
    204, 6, 173, 30, 14, 74, 74, 74, 74, 74, 9, 40, 168, 177, 236, 24,
    32, 255, 255, 169, 0, 149, 240, 76, 248, 5, 189, 9, 14, 240, 18, 222,
    13, 14, 208, 13, 157, 13, 14, 189, 193, 13, 41, 15, 240, 3, 222, 193,
    13, 160, 35, 177, 236, 149, 240, 189, 17, 14, 24, 105, 37, 168, 41, 3,
    157, 17, 14, 136, 177, 236, 125, 209, 13, 157, 225, 13, 32, 119, 9, 157,
    201, 13, 189, 5, 14, 240, 6, 222, 5, 14, 76, 223, 5, 189, 189, 13,
    141, 30, 7, 16, 254, 76, 194, 8, 0, 76, 229, 8, 0, 76, 251, 8,
    0, 76, 21, 9, 0, 76, 37, 9, 0, 76, 56, 9, 0, 76, 66, 9,
    16, 76, 72, 9, 169, 0, 157, 197, 13, 172, 31, 14, 136, 200, 177, 236,
    201, 254, 208, 4, 140, 31, 14, 96, 201, 224, 144, 8, 173, 187, 13, 141,
    23, 14, 208, 233, 201, 208, 144, 10, 41, 15, 141, 188, 13, 141, 21, 14,
    16, 219, 201, 192, 144, 9, 41, 15, 73, 15, 157, 197, 13, 16, 206, 201,
    128, 144, 7, 41, 63, 157, 241, 13, 16, 195, 201, 64, 144, 27, 200, 140,
    31, 14, 41, 31, 157, 229, 13, 10, 168, 185, 255, 255, 157, 217, 13, 200,
    185, 255, 255, 157, 221, 13, 76, 62, 7, 140, 31, 14, 141, 30, 14, 24,
    125, 213, 13, 157, 209, 13, 173, 27, 14, 240, 66, 201, 2, 240, 58, 189,
    229, 13, 201, 31, 208, 55, 173, 30, 14, 56, 233, 1, 41, 15, 168, 177,
    254, 133, 253, 152, 9, 16, 168, 177, 254, 133, 248, 160, 1, 5, 253, 208,
    2, 160, 0, 140, 26, 14, 169, 0, 133, 252, 157, 217, 13, 157, 221, 13,
    138, 10, 141, 24, 14, 142, 25, 14, 96, 224, 2, 176, 99, 189, 217, 13,
    133, 238, 189, 221, 13, 133, 239, 5, 238, 240, 74, 160, 32, 177, 238, 41,
    15, 157, 249, 13, 177, 238, 41, 112, 74, 74, 157, 189, 13, 200, 177, 238,
    10, 10, 72, 41, 63, 157, 5, 14, 104, 41, 192, 157, 205, 13, 200, 177,
    238, 157, 9, 14, 157, 13, 14, 169, 0, 149, 244, 157, 17, 14, 157, 253,
    13, 157, 1, 14, 189, 209, 13, 157, 225, 13, 32, 117, 9, 157, 201, 13,
    236, 25, 14, 240, 1, 96, 160, 255, 140, 25, 14, 200, 140, 26, 14, 96,
    224, 2, 208, 51, 172, 211, 13, 185, 69, 11, 141, 121, 13, 185, 129, 11,
    141, 127, 13, 169, 0, 133, 249, 133, 250, 173, 231, 13, 41, 15, 168, 177,
    254, 133, 251, 152, 9, 16, 168, 177, 254, 141, 137, 13, 5, 251, 208, 6,
    141, 121, 13, 141, 127, 13, 96, 173, 232, 13, 41, 15, 168, 177, 254, 133,
    253, 152, 9, 16, 168, 177, 254, 5, 253, 240, 15, 177, 254, 56, 229, 253,
    133, 248, 169, 0, 133, 252, 169, 141, 208, 2, 169, 173, 141, 97, 13, 141,
    56, 13, 169, 24, 141, 7, 210, 96, 173, 29, 14, 41, 7, 74, 74, 144,
    18, 208, 24, 189, 249, 13, 24, 157, 1, 14, 125, 201, 13, 157, 201, 13,
    76, 223, 5, 169, 0, 157, 1, 14, 76, 223, 5, 189, 201, 13, 56, 253,
    249, 13, 157, 201, 13, 56, 169, 0, 253, 249, 13, 157, 1, 14, 76, 223,
    5, 189, 253, 13, 24, 157, 1, 14, 125, 201, 13, 157, 201, 13, 24, 189,
    253, 13, 125, 249, 13, 157, 253, 13, 76, 223, 5, 189, 225, 13, 56, 253,
    253, 13, 157, 225, 13, 32, 117, 9, 76, 5, 9, 169, 0, 56, 253, 253,
    13, 157, 1, 14, 189, 201, 13, 56, 253, 253, 13, 76, 5, 9, 189, 225,
    13, 24, 125, 253, 13, 76, 28, 9, 32, 85, 9, 76, 208, 8, 32, 85,
    9, 24, 125, 225, 13, 32, 155, 9, 76, 223, 5, 188, 253, 13, 189, 249,
    13, 48, 2, 200, 200, 136, 152, 157, 253, 13, 221, 249, 13, 208, 8, 189,
    249, 13, 73, 255, 157, 249, 13, 189, 253, 13, 96, 41, 63, 29, 205, 13,
    168, 185, 255, 255, 96, 148, 145, 152, 165, 173, 180, 192, 9, 9, 9, 9,
    9, 9, 9, 64, 0, 32, 0, 125, 201, 13, 157, 201, 13, 96, 125, 209,
    13, 157, 225, 13, 32, 117, 9, 157, 201, 13, 96, 157, 201, 13, 189, 141,
    9, 16, 12, 157, 201, 13, 169, 128, 208, 5, 157, 201, 13, 169, 1, 13,
    28, 14, 141, 28, 14, 96, 45, 10, 210, 157, 201, 13, 96, 242, 51, 150,
    226, 56, 140, 0, 106, 232, 106, 239, 128, 8, 174, 70, 230, 149, 65, 246,
    176, 110, 48, 246, 187, 132, 82, 34, 244, 200, 160, 122, 85, 52, 20, 245,
    216, 189, 164, 141, 119, 96, 78, 56, 39, 21, 6, 247, 232, 219, 207, 195,
    184, 172, 162, 154, 144, 136, 127, 120, 112, 106, 100, 94, 13, 13, 12, 11,
    11, 10, 10, 9, 8, 8, 7, 7, 7, 6, 6, 5, 5, 5, 4, 4,
    4, 4, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24, 24, 24, 24, 24,
    24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 22, 22, 23, 23, 23,
    23, 24, 24, 24, 24, 24, 25, 25, 25, 25, 26, 21, 21, 22, 22, 22,
    23, 23, 24, 24, 24, 25, 25, 26, 26, 26, 27, 20, 21, 21, 22, 22,
    23, 23, 24, 24, 24, 25, 25, 26, 26, 27, 27, 20, 20, 21, 21, 22,
    22, 23, 23, 24, 25, 25, 26, 26, 27, 27, 28, 19, 20, 20, 21, 22,
    22, 23, 23, 24, 25, 25, 26, 26, 27, 28, 28, 19, 19, 20, 21, 21,
    22, 23, 23, 24, 25, 25, 26, 27, 27, 28, 29, 18, 19, 20, 20, 21,
    22, 23, 23, 24, 25, 25, 26, 27, 28, 28, 29, 18, 19, 19, 20, 21,
    22, 22, 23, 24, 25, 26, 26, 27, 28, 29, 29, 18, 18, 19, 20, 21,
    22, 22, 23, 24, 25, 26, 26, 27, 28, 29, 30, 17, 18, 19, 20, 21,
    22, 22, 23, 24, 25, 26, 26, 27, 28, 29, 30, 17, 18, 19, 20, 21,
    21, 22, 23, 24, 25, 26, 27, 27, 28, 29, 30, 17, 18, 19, 20, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 28, 29, 30, 17, 18, 19, 19, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 29, 29, 30, 17, 18, 18, 19, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 30, 16, 17, 18, 19, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 34, 36, 38, 41,
    43, 46, 48, 51, 55, 58, 61, 65, 69, 73, 77, 82, 87, 92, 97, 103,
    110, 116, 123, 130, 138, 146, 155, 164, 174, 184, 195, 207, 220, 233, 246, 5,
    21, 37, 55, 73, 93, 113, 135, 159, 184, 210, 237, 11, 42, 75, 110, 147,
    186, 227, 15, 62, 112, 164, 219, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 3,
    3, 3, 3, 229, 42, 64, 89, 100, 238, 8, 166, 11, 12, 12, 12, 12,
    12, 13, 13, 142, 50, 7, 140, 54, 7, 41, 7, 168, 185, 189, 11, 141,
    227, 11, 185, 197, 11, 141, 228, 11, 76, 255, 255, 173, 54, 7, 174, 50,
    7, 141, 148, 7, 141, 155, 7, 142, 149, 7, 142, 156, 7, 24, 105, 64,
    141, 129, 5, 141, 135, 5, 144, 1, 232, 142, 130, 5, 142, 136, 5, 24,
    105, 128, 141, 124, 9, 144, 1, 232, 142, 125, 9, 232, 141, 31, 12, 142,
    32, 12, 162, 9, 189, 255, 255, 157, 179, 13, 202, 16, 247, 206, 188, 13,
    169, 0, 141, 46, 7, 162, 98, 157, 189, 13, 202, 16, 250, 162, 8, 157,
    0, 210, 202, 16, 250, 96, 32, 42, 12, 173, 50, 7, 10, 141, 22, 14,
    173, 187, 13, 141, 23, 14, 169, 1, 141, 21, 14, 141, 46, 7, 96, 173,
    54, 7, 133, 254, 173, 50, 7, 133, 255, 96, 173, 54, 7, 41, 3, 170,
    173, 50, 7, 32, 198, 7, 173, 26, 14, 240, 238, 14, 54, 7, 32, 190,
    12, 169, 1, 141, 27, 14, 173, 26, 14, 240, 222, 201, 1, 208, 5, 160,
    0, 238, 26, 14, 177, 252, 174, 24, 14, 74, 74, 74, 74, 9, 16, 141,
    10, 212, 141, 10, 212, 157, 1, 210, 177, 252, 9, 16, 141, 10, 212, 141,
    10, 212, 157, 1, 210, 200, 208, 206, 230, 253, 165, 253, 197, 248, 208, 198,
    140, 26, 14, 96, 144, 21, 169, 234, 141, 153, 12, 141, 154, 12, 141, 155,
    12, 141, 166, 12, 141, 167, 12, 141, 168, 12, 96, 169, 141, 141, 153, 12,
    141, 166, 12, 169, 10, 141, 154, 12, 141, 167, 12, 169, 212, 141, 155, 12,
    141, 168, 12, 96, 169, 0, 141, 26, 14, 173, 50, 7, 74, 32, 190, 12,
    169, 1, 141, 27, 14, 32, 128, 12, 173, 27, 14, 208, 248, 96, 169, 2,
    141, 27, 14, 141, 25, 14, 169, 24, 141, 7, 210, 169, 17, 133, 250, 169,
    13, 133, 251, 169, 173, 141, 97, 13, 141, 56, 13, 160, 0, 140, 121, 13,
    140, 127, 13, 174, 11, 212, 177, 252, 74, 74, 74, 74, 9, 16, 141, 7,
    210, 32, 117, 13, 236, 11, 212, 240, 251, 141, 5, 210, 174, 11, 212, 177,
    252, 230, 252, 208, 16, 230, 253, 198, 248, 208, 10, 169, 173, 141, 97, 13,
    141, 56, 13, 169, 8, 9, 16, 141, 7, 210, 32, 117, 13, 236, 11, 212,
    240, 251, 141, 5, 210, 173, 27, 14, 208, 185, 96, 24, 165, 249, 105, 0,
    133, 249, 165, 250, 105, 0, 133, 250, 144, 15, 230, 251, 165, 251, 201, 0,
    208, 7, 140, 121, 13, 140, 127, 13, 96, 177, 250, 36, 249, 48, 4, 74,
    74, 74, 74, 41, 15, 168, 185, 69, 10, 160, 0, 96, 160, 0, 140, 27,
    14, 140, 26, 14, 136, 140, 25, 14, 96);

procedure Need(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise EArgumentException.Create('Atari MPT: ' + MessageText);
end;

function ByteAt(const Data: TBytes; Offset: Integer): Integer;
begin
  Need((Offset >= 0) and (Offset < Length(Data)), 'truncated module');
  Result := Data[Offset];
end;

function WordAt(const Data: TBytes; Offset: Integer): Integer;
begin
  Result := ByteAt(Data, Offset) + ByteAt(Data, Offset + 1) * 256;
end;

function ValidateSamples(const Data: TBytes): Integer;
begin
  Need((Length(Data) >= 288) and (Length(Data) <= 12320), 'invalid sample bank size');
  var Last := -1;
  Result := 0;
  for var I := 0 to 15 do
  begin
    var Start := Integer(Data[I]);
    var Finish := Integer(Data[16 + I]);
    if Start = 0 then
    begin
      for var J := I to 15 do
        Need((Data[J] = 0) and (Data[16 + J] = 0), 'invalid unused sample');
      Break;
    end;
    Need((Start > 0) and (Finish > Start), 'sample page range');
    Need((I = 0) or (Start = Last), 'noncontiguous sample bank');
    Last := Finish;
    Inc(Result);
  end;
  Need(Result > 0, 'empty sample bank');
  Need(Length(Data) >= 32 + (Last - Integer(Data[0])) * 256, 'sample bank length');
end;

procedure LoadMPTSamples(State: TASAP; const Data: TBytes);
begin
  var Count := ValidateSamples(Data);
  var M := State.moduleInfo;
  M.kind := ASAPModuleType_D15;
  M.music := Integer(Data[0]) * 256 - 32;
  M.fastplay := 1;
  M.songs := 0;
  Need((M.music >= 0) and (Length(Data) <= 65536 - M.music), 'sample load address');
  for var I := 0 to Count - 1 do
  begin
    var Nibbles := (Integer(Data[16 + I]) - Integer(Data[I])) * 512;
    // Sampling pauses during the first eleven scanlines of each video frame.
    ASAPInfo_AddSong(M, Nibbles + Nibbles div 301 * 11);
  end;
  for var I := 0 to High(Data) do
    State.cpu.memory[M.music + I] := Data[I];
end;

procedure ParseSong(M: TASAPInfo; const Data: TBytes; var GlobalSeen: TArray<Boolean>; SongLength, StartPosition: Integer);
var
  Seen: array[0..255] of Byte;
  Pattern, Blanks, Remaining: array[0..3] of Integer;
begin
  FillChar(Seen, SizeOf(Seen), 0);
  FillChar(Blanks, SizeOf(Blanks), 0);
  var AddressBase := WordAt(Data, 2) - 6;
  var Tempo := ByteAt(Data, 463);
  var Position := StartPosition;
  var Calls := 0;
  var Commands := 0;
  while Position < SongLength do
  begin
    if Seen[Position] <> 0 then
    begin
      M.loops[M.songs] := Seen[Position] = 2;
      Break;
    end;
    Seen[Position] := 1;
    GlobalSeen[Position] := True;
    if ByteAt(Data, 464 + Position * 2) = 255 then
    begin
      Position := ByteAt(Data, 465 + Position * 2);
      Continue;
    end;
    var Stop := False;
    for var C := 3 downto 0 do
    begin
      var Table := ByteAt(Data, 454 + C) + ByteAt(Data, 458 + C) * 256 - AddressBase;
      var Index := ByteAt(Data, Table + Position * 2);
      if Index >= 64 then
      begin
        Stop := True;
        Break;
      end;
      var Address := WordAt(Data, 70 + Index * 2);
      Pattern[C] := 0;
      if Address <> 0 then
        Pattern[C] := Address - AddressBase;
      Remaining[C] := 0;
    end;
    if Stop then
      Break;
    for var I := 0 to SongLength - 1 do
      if Seen[I] = 1 then
        Seen[I] := 2;
    var Rows := ByteAt(Data, 462);
    while Rows > 0 do
    begin
      Dec(Rows);
      for var C := 3 downto 0 do
      begin
        if Pattern[C] = 0 then
          Continue;
        Dec(Remaining[C]);
        if Remaining[C] >= 0 then
          Continue;
        while True do
        begin
          Inc(Commands);
          Need(Commands <= 1000000, 'pattern command limit');
          var V := ByteAt(Data, Pattern[C]);
          Inc(Pattern[C]);
          if (V < 64) or (V = 254) then
            Break;
          if (V >= 128) and (V < 192) then
            Blanks[C] := V - 128
          else if (V >= 208) and (V < 224) then
            Tempo := V - 207
          else if V >= 224 then
            Rows := 0;
        end;
        Remaining[C] := Blanks[C];
      end;
      Inc(Calls, Tempo);
      Need(Calls <= 1000000, 'song duration limit');
    end;
    Inc(Position);
  end;
  if Calls > 0 then
    ASAPInfo_AddSong(M, Calls);
end;

procedure LoadMD1(State: TASAP; const Module, Samples: TBytes; Is15kHz: Boolean);
begin
  Need((Length(Module) >= 464) and (Length(Module) <= 65000), 'invalid MD1 size');
  var M := State.moduleInfo;
  M.kind := ASAPModuleType_MD1;
  Need(ASAPInfo_ParseModule(M, Module, Length(Module)), 'invalid MD1 load block');
  Need((ByteAt(Module, 462) > 0) and (ByteAt(Module, 463) > 0), 'zero pattern length/tempo');
  var TableStart := M.music + 458;
  Need(ByteAt(Module, 454) + ByteAt(Module, 458) * 256 = TableStart, 'invalid song table');
  var Distance := ByteAt(Module, 455) + ByteAt(Module, 459) * 256 - TableStart;
  Need((Distance > 0) and (Distance <= 508) and not Odd(Distance), 'song table length');
  var SongLength := Distance div 2;
  for var C := 0 to 3 do
  begin
    var Offset := ByteAt(Module, 454 + C) + ByteAt(Module, 458 + C) * 256 - M.music + 6;
    Need((Offset >= 464) and (SongLength * 2 <= Length(Module) - Offset), 'channel order range');
  end;
  var Seen: TArray<Boolean>;
  SetLength(Seen, SongLength);
  M.songs := 0;
  for var I := 0 to SongLength - 1 do
    if not Seen[I] then
    begin
      if M.songs = 32 then
        Break;
      M.songPos[M.songs] := I;
      ParseSong(M, Module, Seen, SongLength, I);
    end;
  Need(M.songs > 0, 'no playable song');
  ValidateSamples(Samples);
  // Move low-address modules above the player and relocate its address tables.
  var Music := M.music;
  if Music < $1000 then
    Music := $1000;
  var MusicLast := Music + Length(Module) - 7;
  Need(MusicLast < $D000, 'module overlaps Atari hardware');
  var Adjust := Music - M.music;
  for var I := 6 to High(Module) do
    State.cpu.memory[Music + I - 6] := Module[I];
  for var I := 0 to 95 do
  begin
    var Address := WordAt(Module, 6 + I * 2);
    if (Address <> 0) and (Address <> 65535) then
    begin
      Need((Address >= M.music) and (Address <= WordAt(Module, 4)), 'instrument/pattern address');
      Inc(Address, Adjust);
    end;
    State.cpu.memory[Music + I * 2] := Address and 255;
    State.cpu.memory[Music + I * 2 + 1] := Address shr 8;
  end;
  for var C := 0 to 3 do
  begin
    var Address := ByteAt(Module, 454 + C) + ByteAt(Module, 458 + C) * 256 + Adjust;
    State.cpu.memory[Music + 448 + C] := Address and 255;
    State.cpu.memory[Music + 452 + C] := Address shr 8;
  end;
  M.music := Music;
  var Bank := Copy(Samples);
  var BankStart := Integer(Bank[0]) * 256 - 32;
  if (BankStart < $F00) or not ((MusicLast < BankStart) or (Music >= BankStart + Length(Bank))) then
  begin
    var FirstPage := ($D020 - Length(Bank)) div 256;
    if $FE0 + Length(Bank) <= Music then
      FirstPage := 16;
    var PageAdjust := FirstPage - Integer(Bank[0]);
    for var I := 0 to 31 do
      if Bank[I] <> 0 then
      begin
        var Page := Integer(Bank[I]) + PageAdjust;
        Need((Page > 0) and (Page <= 255), 'sample relocation range');
        Bank[I] := Page;
      end;
    BankStart := Integer(Bank[0]) * 256 - 32;
  end;
  Need((BankStart >= $F00) and (BankStart + Length(Bank) <= $D000) and
    ((MusicLast < BankStart) or (Music >= BankStart + Length(Bank))), 'sample bank overlaps module/hardware');
  State.mptSamplesPage := Bank[0];
  State.mptSamples15kHz := Is15kHz;
  for var I := 0 to High(Bank) do
    State.cpu.memory[BankStart + I] := Bank[I];
  var PlayerStart := Integer(MPTPlayer[2]) + Integer(MPTPlayer[3]) * 256;
  for var I := 6 to High(MPTPlayer) do
    State.cpu.memory[PlayerStart + I - 6] := MPTPlayer[I];
  M.player := PlayerStart;
end;

end.

