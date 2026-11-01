unit Core.RAR.Unpack;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
{$POINTERMATH ON}

// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

//  TUnpack — main decompressor class covering RAR 1.5, 2.0, 3.0 and 5.0.
//  Translated from unpack.cpp / unpack50.cpp / unpack30.cpp /
//  unpack20.cpp / unpack15.cpp / unpackinline.cpp.

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Core.RAR.Types, Core.RAR.GetBits, Core.RAR.VM, Core.RAR.PPM,
  Core.RAR.FragWindow;

type
  TUnpack = class(TUnpackBase)
  private
    FInp: TBitInput;
    FVMCodeInp: TBitInput;

    // RAR5 filter staging buffers
    FFilterSrcMemory: array of Byte;
    FFilterDstMemory: array of Byte;
    // RAR5 filter queue
    FFilters: array of TUnpackFilter;

    FOldDist: array[0..3] of NativeUInt;
    FOldDistPtr: NativeUInt;
    FLastLength: LongWord;
    FLastDist: LongWord;   // RAR2/1.5 only

    FUnpPtr: NativeUInt;
    FPrevPtr: NativeUInt;
    FFirstWinDone: Boolean;
    FWrPtr: NativeUInt;
    FReadTop: Integer;
    FReadBorder: Integer;
    FBlockHeader: TUnpackBlockHeader;
    FBlockTables: TUnpackBlockTables;
    FWriteBorder: NativeUInt;
    FWindow: PByte;
    FFragWindow: TFragmentedWindow;
    FFragmented: Boolean;
    FDestUnpSize: Int64;
    FSuspended: Boolean;
    FUnpSomeRead: Boolean;
    FWrittenFileSize: Int64;
    FFileExtracted: Boolean;

    //--- RAR 1.5 ---------------------------------------------------------------
    FChSet: array[0..255] of Word;
    FChSetA: array[0..255] of Word;
    FChSetB: array[0..255] of Word;
    FChSetC: array[0..255] of Word;
    FNToPl: array[0..255] of Byte;
    FNToPlB: array[0..255] of Byte;
    FNToPlC: array[0..255] of Byte;
    FFlagBuf, FAvrPlc, FAvrPlcB, FAvrLn1, FAvrLn2, FAvrLn3: LongWord;
    FBuf60, FNumHuf, FStMode, FLCount, FFlagsCnt: Integer;
    FNhfb, FNlzb, FMaxDist3: LongWord;

    //--- RAR 2.0 ---------------------------------------------------------------
    FMD: array[0..3] of TDecodeTable;
    FUnpOldTable20: array[0..MC20 * 4 - 1] of Byte;
    FUnpAudioBlock: Boolean;
    FUnpChannels: LongWord;
    FUnpCurChannel: LongWord;
    FUnpChannelDelta: Integer;
    FAudV: array[0..3] of TAudioVariables;

    //--- RAR 3.0 ---------------------------------------------------------------
    FPrevLowDist, FLowDistRepCount: Integer;
    FPPM: TModelPPM;
    FPPMEscChar: Integer;
    FUnpOldTable: array[0..HUFF_TABLE_SIZE30 - 1] of Byte;
    FUnpBlockType: Integer;
    FTablesRead2, FTablesRead3, FTablesRead5: Boolean;
    FVM: TRarVM;
    FFilters30: array of PUnpackFilter30;
    FPrgStack: array of PUnpackFilter30;
    FOldFilterLengths: array of Integer;
    FLastFilter: Integer;

    //--- helpers ---------------------------------------------------------------
    function WrapDown(WinPos: NativeUInt): NativeUInt; {$IFDEF FPC} inline;{$ENDIF}
    function WrapUp(WinPos: NativeUInt): NativeUInt; {$IFDEF FPC} inline;{$ENDIF}
    procedure InsertOldDist(Distance: NativeUInt);   {$IFDEF FPC} inline;{$ENDIF}
    procedure CopyString(ALength: LongWord; Distance: NativeUInt); {$IFDEF FPC} inline;{$ENDIF}
    function DecodeNumber(AInp: TBitInput; Dec: PDecodeTable): LongWord; {$IFDEF FPC} inline;{$ENDIF}
    function SlotToLength(AInp: TBitInput; Slot: LongWord): LongWord;   {$IFDEF FPC} inline;{$ENDIF}

    //--- core ------------------------------------------------------------------
    procedure MakeDecodeTables(LengthTable: PByte; Dec: PDecodeTable; Size: LongWord);
    procedure UnpInitData(Solid: Boolean);
    function UnpReadBuf: Boolean;
    procedure UnpWriteBuf;
    procedure UnpWriteArea(StartPtr, EndPtr: NativeUInt);
    procedure UnpWriteData(Data: PByte; Size: NativeUInt);
    function ApplyFilter(Data: PByte; DataSize: LongWord; Flt: PUnpackFilter): PByte;
    procedure InitFilters;

    //--- RAR 5.0 ---------------------------------------------------------------
    procedure Unpack5(Solid: Boolean);
    procedure UnpInitData50(Solid: Boolean);
    function ReadBlockHeader(AInp: TBitInput; var Header: TUnpackBlockHeader): Boolean;
    function ReadTables(AInp: TBitInput; var Header: TUnpackBlockHeader; var Tables: TUnpackBlockTables): Boolean;
    function ReadFilterData(AInp: TBitInput): LongWord;
    function ReadFilter(AInp: TBitInput; var Filter: TUnpackFilter): Boolean;
    function AddFilter(var Filter: TUnpackFilter): Boolean;

    //--- RAR 3.0 ---------------------------------------------------------------
    procedure Unpack29(Solid: Boolean);
    procedure UnpInitData30(Solid: Boolean);
    procedure InitFilters30(Solid: Boolean);
    function ReadEndOfBlock: Boolean;
    function ReadVMCode: Boolean;
    function ReadVMCodePPM: Boolean;
    function AddVMCode(FirstByte: LongWord; Code: PByte; CodeSize: LongWord): Boolean;
    function SafePPMDecodeChar: Integer;
    function ReadTables30: Boolean;
    function UnpReadBuf30: Boolean;
    procedure UnpWriteBuf30;
    procedure ExecuteCode(Prg: PVM_PreparedProgram);

    //--- RAR 2.0 ---------------------------------------------------------------
    procedure Unpack20(Solid: Boolean);
    procedure UnpInitData20(Solid: Boolean);
    procedure CopyString20(ALength, Distance: LongWord);
    function ReadTables20: Boolean;
    procedure UnpWriteBuf20;
    procedure ReadLastTables;
    function DecodeAudio(Delta: Integer): Byte;

    //--- RAR 1.5 ---------------------------------------------------------------
    procedure Unpack15(Solid: Boolean);
    procedure UnpInitData15(Solid: Boolean);
    procedure InitHuff;
    procedure ShortLZ;
    procedure LongLZ;
    procedure HuffDecode;
    procedure GetFlagsBuf;
    procedure CorrHuff(CharSet: PWord; NumToPlace: PByte);
    procedure CopyString15(Distance, ALength: LongWord);
    function DecodeNum(Num, StartPos: LongWord; DecTab, PosTab: PLongWord): LongWord;

  public
    AllocWinSize: UInt64;
    MaxWinSize: NativeUInt;
    MaxWinMask: NativeUInt;
    ExtraDist: Boolean;
    UnpIO: TComprDataIO;

    constructor Create(ADataIO: TComprDataIO);
    destructor Destroy; override;
    procedure Init(WinSize: UInt64; Solid: Boolean);
    procedure DoUnpack(Method: LongWord; Solid: Boolean);
    function IsFileExtracted: Boolean;
    procedure SetDestSize(DestSize: Int64);
    procedure SetSuspended(ASuspended: Boolean);
    function GetChar: Byte; override;
  end;

implementation

// ── Unit-level constants for static tables ────────────────────────────────────

const
  // Shared by Unpack29 and Unpack20
  LDecode29: array[0..27] of Byte =
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224);
  LBits29: array[0..27] of Byte =
    (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5);
  SDDecode: array[0..7] of Byte = (0, 4, 8, 16, 32, 64, 128, 192);
  SDBits: array[0..7] of Byte = (2, 2, 3, 4, 5, 6, 6, 6);

  // Unpack29 distance table initialiser
  DBitLengthCounts: array[0..18] of Integer =
    (4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 14, 0, 12);

  // Unpack20 distance tables
  DDecode20: array[0..47] of LongWord =
    (0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768,
    1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152,
    65536, 98304, 131072, 196608, 262144, 327680, 393216, 458752, 524288, 589824,
    655360, 720896, 786432, 851968, 917504, 983040);
  DBits20: array[0..47] of Byte =
    (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
    13, 13, 14, 14, 15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16);

  // Unpack15 Huffman tables
  STARTL1 = 2;
  STARTL2 = 3;
  STARTHF0 = 4;
  STARTHF1 = 5;
  STARTHF2 = 5;
  STARTHF3 = 6;
  STARTHF4 = 8;
  DecL1: array[0..10] of LongWord =
    ($8000, $a000, $c000, $d000, $e000, $ea00, $ee00, $f000, $f200, $f200, $ffff);
  PosL1: array[0..12] of LongWord =
    (0, 0, 0, 2, 3, 5, 7, 11, 16, 20, 24, 32, 32);
  DecL2: array[0..9] of LongWord =
    ($a000, $c000, $d000, $e000, $ea00, $ee00, $f000, $f200, $f240, $ffff);
  PosL2: array[0..12] of LongWord =
    (0, 0, 0, 0, 5, 7, 9, 13, 18, 22, 26, 34, 36);
  DecHf0: array[0..8] of LongWord =
    ($8000, $c000, $e000, $f200, $f200, $f200, $f200, $f200, $ffff);
  PosHf0: array[0..12] of LongWord =
    (0, 0, 0, 0, 0, 8, 16, 24, 33, 33, 33, 33, 33);
  DecHf1: array[0..7] of LongWord =
    ($2000, $c000, $e000, $f000, $f200, $f200, $f7e0, $ffff);
  PosHf1: array[0..12] of LongWord =
    (0, 0, 0, 0, 0, 0, 4, 44, 60, 76, 80, 80, 127);
  DecHf2: array[0..7] of LongWord =
    ($1000, $2400, $8000, $c000, $fa00, $ffff, $ffff, $ffff);
  PosHf2: array[0..12] of LongWord =
    (0, 0, 0, 0, 0, 0, 2, 7, 53, 117, 233, 0, 0);
  DecHf3: array[0..6] of LongWord =
    ($800, $2400, $ee00, $fe80, $ffff, $ffff, $ffff);
  PosHf3: array[0..12] of LongWord =
    (0, 0, 0, 0, 0, 0, 0, 2, 16, 218, 251, 0, 0);
  DecHf4: array[0..5] of LongWord =
    ($ff00, $ffff, $ffff, $ffff, $ffff, $ffff);
  PosHf4: array[0..12] of LongWord =
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0);
  ShortLen1: array[0..14] of LongWord =
    (1, 3, 4, 4, 5, 6, 7, 8, 8, 4, 4, 5, 6, 6, 4);
  ShortXor1: array[0..14] of LongWord =
    (0, $a0, $d0, $e0, $f0, $f8, $fc, $fe, $ff, $c0, $80, $90, $98, $9c, $b0);
  ShortLen2: array[0..14] of LongWord =
    (2, 3, 3, 3, 4, 4, 5, 6, 6, 4, 4, 5, 6, 6, 4);
  ShortXor2: array[0..14] of LongWord =
    (0, $40, $60, $a0, $d0, $e0, $f0, $f8, $fc, $c0, $80, $90, $98, $9c, $b0);

// Lazily-initialised Unpack29 distance tables
var
  Unp29DDecode: array[0..DC30 - 1] of Integer;
  Unp29DBits: array[0..DC30 - 1] of Byte;
  Unp29DDecodeInited: Boolean = False;

// ── TUnpack ────────────────────────────────────────────────────────────────────

constructor TUnpack.Create(ADataIO: TComprDataIO);
begin
  inherited Create;
  UnpIO := ADataIO;
  FInp := TBitInput.Create(True);
  FVMCodeInp := TBitInput.Create(True);
  FFragWindow := TFragmentedWindow.Create;
  FPPM := TModelPPM.Create;
  FVM := TRarVM.Create;
  FWindow := nil;
  FFragmented := False;
  FSuspended := False;
  FUnpSomeRead := False;
  ExtraDist := False;
  AllocWinSize := 0;
  MaxWinSize := 0;
  MaxWinMask := 0;
  UnpInitData(False);
  UnpInitData15(False);
  InitHuff;
end;

destructor TUnpack.Destroy;
begin
  InitFilters30(False);
  if FWindow <> nil then
    FreeMem(FWindow);
  FVM.Free;
  FPPM.Free;
  FFragWindow.Free;
  FVMCodeInp.Free;
  FInp.Free;
  inherited;
end;

// ── Public interface ──────────────────────────────────────────────────────────

function TUnpack.IsFileExtracted: Boolean;
begin
  Result := FFileExtracted;
end;

procedure TUnpack.SetDestSize(DestSize: Int64);
begin
  FDestUnpSize := DestSize;
  FFileExtracted := False;
end;

procedure TUnpack.SetSuspended(ASuspended: Boolean);
begin
  FSuspended := ASuspended;
end;

function TUnpack.GetChar: Byte;
begin
  if FInp.InAddr > BITINPUT_MAX_SIZE - 30 then
  begin
    UnpReadBuf;
    if FInp.InAddr >= BITINPUT_MAX_SIZE then
    begin
      Result := 0;
      Exit;
    end;
  end;
  Result := FInp.InBuf[FInp.InAddr];
  Inc(FInp.InAddr);
end;

procedure TUnpack.Init(WinSize: UInt64; Solid: Boolean);
begin
  if WinSize < $40000 then
    WinSize := $40000;
  if WinSize > UNPACK_MAX_DICT then
    raise EOutOfMemory.Create('Unpack.Init: WinSize > UNPACK_MAX_DICT');
  if (WinSize > $80000000) and (SizeOf(NativeUInt) <= 4) then
    raise EOutOfMemory.Create('Unpack.Init: WinSize > 2GB on 32-bit');

  if not Solid or (FWindow = nil) then
  begin
    MaxWinSize := NativeUInt(WinSize);
    MaxWinMask := MaxWinSize - 1;
  end;

  if WinSize <= AllocWinSize then
    Exit;

  if Solid and ((FWindow <> nil) or
    (FFragmented and (WinSize > FFragWindow.GetWinSize))) then
    raise EOutOfMemory.Create('Unpack.Init: Cannot grow solid window');

  if FWindow <> nil then
    FreeMem(FWindow);
  FWindow := nil;

  if not FFragmented then
  begin
    try
      GetMem(FWindow, NativeUInt(WinSize));
    except
      on EOutOfMemory do
        FWindow := nil;
    end;
  end;

  if FWindow = nil then
  begin
    if (WinSize < $1000000) or (SizeOf(NativeUInt) > 4) then
      raise EOutOfMemory.Create('Unpack.Init: Cannot allocate window');
    if WinSize > FFragWindow.GetWinSize then
      FFragWindow.Init(NativeUInt(WinSize));
    FFragmented := True;
  end
  else
    AllocWinSize := WinSize;
end;

procedure TUnpack.DoUnpack(Method: LongWord; Solid: Boolean);
begin
  case Method of
    15:
      if not FFragmented then
        Unpack15(Solid);
    20, 26:
      if not FFragmented then
        Unpack20(Solid);
    29:
      if not FFragmented then
        Unpack29(Solid);
    VER_PACK5, VER_PACK7:
      begin
        ExtraDist := (Method = VER_PACK7);
        Unpack5(Solid);
      end;
  end;
end;

// ── Inline helpers ────────────────────────────────────────────────────────────

function TUnpack.WrapDown(WinPos: NativeUInt): NativeUInt;
begin
  if WinPos >= MaxWinSize then
    Result := WinPos + MaxWinSize
  else
    Result := WinPos;
end;

function TUnpack.WrapUp(WinPos: NativeUInt): NativeUInt;
begin
  if WinPos >= MaxWinSize then
    Result := WinPos - MaxWinSize
  else
    Result := WinPos;
end;

procedure TUnpack.InsertOldDist(Distance: NativeUInt);
begin
  FOldDist[3] := FOldDist[2];
  FOldDist[2] := FOldDist[1];
  FOldDist[1] := FOldDist[0];
  FOldDist[0] := Distance;
end;

procedure TUnpack.CopyString(ALength: LongWord; Distance: NativeUInt);
var
  SrcPtr: NativeUInt;
  Src, Dest: PByte;
begin
  SrcPtr := FUnpPtr - Distance;
  if Distance > FUnpPtr then
  begin
    Inc(SrcPtr, MaxWinSize);
    if (Distance > MaxWinSize) or not FFirstWinDone then
    begin
      while ALength > 0 do
      begin
        FWindow[FUnpPtr] := 0;
        FUnpPtr := WrapUp(FUnpPtr + 1);
        Dec(ALength);
      end;
      Exit;
    end;
  end;

  if (SrcPtr < MaxWinSize - MAX_INC_LZ_MATCH) and
    (FUnpPtr < MaxWinSize - MAX_INC_LZ_MATCH) then
  begin
    Src := FWindow + SrcPtr;
    Dest := FWindow + FUnpPtr;
    Inc(FUnpPtr, ALength);
    while ALength >= 8 do
    begin
      Dest[0] := Src[0];
      Dest[1] := Src[1];
      Dest[2] := Src[2];
      Dest[3] := Src[3];
      Dest[4] := Src[4];
      Dest[5] := Src[5];
      Dest[6] := Src[6];
      Dest[7] := Src[7];
      Inc(Src, 8);
      Inc(Dest, 8);
      Dec(ALength, 8);
    end;
    if ALength > 0 then
    begin
      Dest[0] := Src[0];
      if ALength > 1 then
      begin
        Dest[1] := Src[1];
        if ALength > 2 then
        begin
          Dest[2] := Src[2];
          if ALength > 3 then
          begin
            Dest[3] := Src[3];
            if ALength > 4 then
            begin
              Dest[4] := Src[4];
              if ALength > 5 then
              begin
                Dest[5] := Src[5];
                if ALength > 6 then
                begin
                  Dest[6] := Src[6];
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end
  else
    while ALength > 0 do
    begin
      FWindow[FUnpPtr] := FWindow[WrapUp(SrcPtr)];
      Inc(SrcPtr);
      FUnpPtr := WrapUp(FUnpPtr + 1);
      Dec(ALength);
    end;
end;

function TUnpack.DecodeNumber(AInp: TBitInput; Dec: PDecodeTable): LongWord;
var
  BitField, Bits, Dist, Pos, I, Code: LongWord;
begin
  BitField := AInp.getbits and $FFFE;
  if BitField < Dec^.DecodeLen[Dec^.QuickBits] then
  begin
    Code := BitField shr (16 - Dec^.QuickBits);
    AInp.addbits(Dec^.QuickLen[Code]);
    Result := Dec^.QuickNum[Code];
    Exit;
  end;
  Bits := 15;
  for I := Dec^.QuickBits + 1 to 14 do
    if BitField < Dec^.DecodeLen[I] then
    begin
      Bits := I;
      Break;
    end;
  // Use faddbits (non-inline) to avoid FPC inline aliasing: addbits(Bits) would
  // corrupt the local Bits variable via Inc(Bits, InBit) in the inlined body.
  AInp.faddbits(Bits);
  Dist := BitField - Dec^.DecodeLen[Bits - 1];
  Dist := Dist shr (16 - Bits);
  Pos := Dec^.DecodePos[Bits] + Dist;
  if Pos >= Dec^.MaxNum then
    Pos := 0;
  Result := Dec^.DecodeNum[Pos];
end;

function TUnpack.SlotToLength(AInp: TBitInput; Slot: LongWord): LongWord;
var
  LBits: LongWord;
begin
  Result := 2;
  if Slot < 8 then
  begin
    LBits := 0;
    Inc(Result, Slot);
  end
  else
  begin
    LBits := Slot div 4 - 1;
    Inc(Result, (4 or (Slot and 3)) shl LBits);
  end;
  if LBits > 0 then
  begin
    Inc(Result, AInp.getbits shr (16 - LBits));
    AInp.addbits(LBits);
  end;
end;

// ── MakeDecodeTables ──────────────────────────────────────────────────────────

procedure TUnpack.MakeDecodeTables(LengthTable: PByte; Dec: PDecodeTable; Size: LongWord);
var
  LengthCount: array[0..15] of LongWord;
  CopyDecodePos: array[0..15] of LongWord;
  UpperLimit, LeftAligned, CurBitLength, QuickDataSize: LongWord;
  I, Code, Dist, BitField, Pos: LongWord;
  CurBL: Byte;
  LastPos: LongWord;
begin
  Dec^.MaxNum := Size;
  FillChar(LengthCount, SizeOf(LengthCount), 0);
  for I := 0 to Size - 1 do
    Inc(LengthCount[LengthTable[I] and $F]);
  LengthCount[0] := 0;
  FillChar(Dec^.DecodeNum, Size * SizeOf(Word), 0);
  Dec^.DecodePos[0] := 0;
  Dec^.DecodeLen[0] := 0;
  UpperLimit := 0;
  for I := 1 to 15 do
  begin
    Inc(UpperLimit, LengthCount[I]);
    LeftAligned := UpperLimit shl (16 - I);
    UpperLimit := UpperLimit * 2;
    Dec^.DecodeLen[I] := LeftAligned;
    Dec^.DecodePos[I] := Dec^.DecodePos[I - 1] + LengthCount[I - 1];
  end;
  Move(Dec^.DecodePos, CopyDecodePos, SizeOf(CopyDecodePos));
  for I := 0 to Size - 1 do
  begin
    CurBL := LengthTable[I] and $F;
    if CurBL <> 0 then
    begin
      LastPos := CopyDecodePos[CurBL];
      Dec^.DecodeNum[LastPos] := Word(I);
      Inc(CopyDecodePos[CurBL]);
    end;
  end;
  case Size of
    NC, NC20, NC30:
      Dec^.QuickBits := MAX_QUICK_DECODE_BITS;
  else
    if MAX_QUICK_DECODE_BITS > 3 then
      Dec^.QuickBits := MAX_QUICK_DECODE_BITS - 3
    else
      Dec^.QuickBits := 0;
  end;
  QuickDataSize := 1 shl Dec^.QuickBits;
  CurBitLength := 1;
  for Code := 0 to QuickDataSize - 1 do
  begin
    BitField := Code shl (16 - Dec^.QuickBits);
    while (CurBitLength < 16) and
      (BitField >= Dec^.DecodeLen[CurBitLength]) do
      Inc(CurBitLength);
    Dec^.QuickLen[Code] := Byte(CurBitLength);
    Dist := BitField - Dec^.DecodeLen[CurBitLength - 1];
    Dist := Dist shr (16 - CurBitLength);
    if CurBitLength < 16 then
    begin
      Pos := Dec^.DecodePos[CurBitLength] + Dist;
      if Pos < Size then
        Dec^.QuickNum[Code] := Dec^.DecodeNum[Pos]
      else
        Dec^.QuickNum[Code] := 0;
    end
    else
      Dec^.QuickNum[Code] := 0;
  end;
end;

// ── UnpInitData ───────────────────────────────────────────────────────────────

procedure TUnpack.UnpInitData(Solid: Boolean);
begin
  if not Solid then
  begin
    FOldDist[0] := NativeUInt(-1);
    FOldDist[1] := NativeUInt(-1);
    FOldDist[2] := NativeUInt(-1);
    FOldDist[3] := NativeUInt(-1);
    FOldDistPtr := 0;
    FLastDist := LongWord(-1);
    FLastLength := 0;
    FillChar(FBlockTables, SizeOf(FBlockTables), 0);
    FUnpPtr := 0;
    FWrPtr := 0;
    FPrevPtr := 0;
    FFirstWinDone := False;
    if MaxWinSize < UNPACK_MAX_WRITE then
      FWriteBorder := MaxWinSize
    else
      FWriteBorder := UNPACK_MAX_WRITE;
  end;
  InitFilters;
  FInp.InitBitInput;
  FWrittenFileSize := 0;
  FReadTop := 0;
  FReadBorder := 0;
  FillChar(FBlockHeader, SizeOf(FBlockHeader), 0);
  FBlockHeader.BlockSize := -1;
  UnpInitData20(Solid);
  UnpInitData30(Solid);
  UnpInitData50(Solid);
end;

// ── UnpReadBuf ────────────────────────────────────────────────────────────────

function TUnpack.UnpReadBuf: Boolean;
var
  DataSize, ReadCode: Integer;
begin
  DataSize := FReadTop - FInp.InAddr;
  if DataSize < 0 then
  begin
    Result := False;
    Exit;
  end;
  Dec(FBlockHeader.BlockSize, FInp.InAddr - FBlockHeader.BlockStart);
  if FInp.InAddr > BITINPUT_MAX_SIZE div 2 then
  begin
    if DataSize > 0 then
      Move(FInp.InBuf[FInp.InAddr], FInp.InBuf[0], DataSize);
    FInp.InAddr := 0;
    FReadTop := DataSize;
  end
  else
    DataSize := FReadTop;
  ReadCode := 0;
  if BITINPUT_MAX_SIZE <> DataSize then
    ReadCode := UnpIO.UnpRead(FInp.InBuf + DataSize, BITINPUT_MAX_SIZE - DataSize);
  if ReadCode > 0 then
    Inc(FReadTop, ReadCode);
  FReadBorder := FReadTop - 30;
  FBlockHeader.BlockStart := FInp.InAddr;
  if FBlockHeader.BlockSize <> -1 then
  begin
    if FBlockHeader.BlockStart + FBlockHeader.BlockSize - 1 < FReadBorder then
      FReadBorder := FBlockHeader.BlockStart + FBlockHeader.BlockSize - 1;
  end;
  Result := (ReadCode <> -1);
end;

// ── UnpWriteBuf (RAR5) ────────────────────────────────────────────────────────

procedure TUnpack.UnpWriteBuf;
var
  WrittenBorder, FullWriteSize, WriteSizeLeft: NativeUInt;
  BlockStart: NativeUInt;
  BlockLength, BlockEnd: NativeUInt;
  FirstPartLen: NativeUInt;
  Mem, OutMem: PByte;
  I, J: Integer;
  Flt: PUnpackFilter;
  EmptyCount: Integer;
  NotAll: Boolean;
begin
  WrittenBorder := FWrPtr;
  FullWriteSize := WrapDown(FUnpPtr - WrittenBorder);
  WriteSizeLeft := FullWriteSize;
  NotAll := False;

  for I := 0 to High(FFilters) do
  begin
    Flt := @FFilters[I];
    if Flt^.FilterType = FILTER_NONE then
      Continue;
    if Flt^.NextWindow then
    begin
      if WrapDown(Flt^.BlockStart - FWrPtr) <= FullWriteSize then
        Flt^.NextWindow := False;
      Continue;
    end;
    BlockStart := Flt^.BlockStart;
    BlockLength := Flt^.BlockLength;
    if WrapDown(BlockStart - WrittenBorder) < WriteSizeLeft then
    begin
      if WrittenBorder <> BlockStart then
      begin
        UnpWriteArea(WrittenBorder, BlockStart);
        WrittenBorder := BlockStart;
        WriteSizeLeft := WrapDown(FUnpPtr - WrittenBorder);
      end;
      if BlockLength <= WriteSizeLeft then
      begin
        if BlockLength > 0 then
        begin
          BlockEnd := WrapUp(BlockStart + BlockLength);
          SetLength(FFilterSrcMemory, BlockLength);
          Mem := @FFilterSrcMemory[0];
          if (BlockStart < BlockEnd) or (BlockEnd = 0) then
          begin
            if FFragmented then
              FFragWindow.CopyData(Mem, BlockStart, BlockLength)
            else
              Move(FWindow[BlockStart], Mem^, BlockLength);
          end
          else
          begin
            FirstPartLen := MaxWinSize - BlockStart;
            if FFragmented then
            begin
              FFragWindow.CopyData(Mem, BlockStart, FirstPartLen);
              FFragWindow.CopyData(Mem + FirstPartLen, 0, BlockEnd);
            end
            else
            begin
              Move(FWindow[BlockStart], Mem^, FirstPartLen);
              Move(FWindow[0], (Mem + FirstPartLen)^, BlockEnd);
            end;
          end;
          OutMem := ApplyFilter(Mem, BlockLength, Flt);
          FFilters[I].FilterType := FILTER_NONE;
          if OutMem <> nil then
            UnpIO.UnpWrite(OutMem, BlockLength);
          FUnpSomeRead := True;
          Inc(FWrittenFileSize, BlockLength);
          WrittenBorder := BlockEnd;
          WriteSizeLeft := WrapDown(FUnpPtr - WrittenBorder);
        end;
      end
      else
      begin
        FWrPtr := WrittenBorder;
        for J := I to High(FFilters) do
          if FFilters[J].FilterType <> FILTER_NONE then
            FFilters[J].NextWindow := False;
        NotAll := True;
        Break;
      end;
    end;
  end;

  // Compact out processed filters
  EmptyCount := 0;
  for I := 0 to High(FFilters) do
  begin
    if EmptyCount > 0 then
      FFilters[I - EmptyCount] := FFilters[I];
    if FFilters[I].FilterType = FILTER_NONE then
      Inc(EmptyCount);
  end;
  if EmptyCount > 0 then
    SetLength(FFilters, Length(FFilters) - EmptyCount);

  if not NotAll then
  begin
    UnpWriteArea(WrittenBorder, FUnpPtr);
    FWrPtr := FUnpPtr;
  end;

  if MaxWinSize < UNPACK_MAX_WRITE then
    FWriteBorder := WrapUp(FUnpPtr + MaxWinSize)
  else
    FWriteBorder := WrapUp(FUnpPtr + UNPACK_MAX_WRITE);

  if (FWriteBorder = FUnpPtr) or
    ((FWrPtr <> FUnpPtr) and
    (WrapDown(FWrPtr - FUnpPtr) < WrapDown(FWriteBorder - FUnpPtr))) then
    FWriteBorder := FWrPtr;
end;

procedure TUnpack.UnpWriteArea(StartPtr, EndPtr: NativeUInt);
var
  SizeToWrite, BlockSize: NativeUInt;
begin
  if EndPtr <> StartPtr then
    FUnpSomeRead := True;
  if FFragmented then
  begin
    SizeToWrite := WrapDown(EndPtr - StartPtr);
    while SizeToWrite > 0 do
    begin
      BlockSize := FFragWindow.GetBlockSize(StartPtr, SizeToWrite);
      UnpWriteData(FFragWindow.BytePtr(StartPtr), BlockSize);
      Dec(SizeToWrite, BlockSize);
      StartPtr := WrapUp(StartPtr + BlockSize);
    end;
  end
  else
  begin
    if EndPtr < StartPtr then
    begin
      UnpWriteData(FWindow + StartPtr, MaxWinSize - StartPtr);
      UnpWriteData(FWindow, EndPtr);
    end
    else
      UnpWriteData(FWindow + StartPtr, EndPtr - StartPtr);
  end;
end;

procedure TUnpack.UnpWriteData(Data: PByte; Size: NativeUInt);
var
  WriteSize: NativeUInt;
  LeftToWrite: Int64;
begin
  if FWrittenFileSize >= FDestUnpSize then
    Exit;
  WriteSize := Size;
  LeftToWrite := FDestUnpSize - FWrittenFileSize;
  if Int64(WriteSize) > LeftToWrite then
    WriteSize := NativeUInt(LeftToWrite);
  UnpIO.UnpWrite(Data, WriteSize);
  Inc(FWrittenFileSize, Size);
end;

// ── ApplyFilter (RAR5) ────────────────────────────────────────────────────────

function TUnpack.ApplyFilter(Data: PByte; DataSize: LongWord; Flt: PUnpackFilter): PByte;
var
  FileOffset, CurPos, Offset, Addr, NewAddr: LongWord;
  CmpByte2: Byte;
  SrcPtr: PByte;
  D: PByte;
  Channels, SrcPos, CurChannel, DestPos: LongWord;
  PrevByte: Byte;
  DstData: PByte;
begin
  Result := Data;
  case Flt^.FilterType of

    FILTER_E8, FILTER_E8E9:
      begin
        FileOffset := LongWord(FWrittenFileSize);
        if Flt^.FilterType = FILTER_E8E9 then
          CmpByte2 := $E9
        else
          CmpByte2 := $E8;
        SrcPtr := Data;
        CurPos := 0;
        while CurPos + 4 < DataSize do
        begin
          if (SrcPtr^ = $E8) or (SrcPtr^ = CmpByte2) then
          begin
            Inc(SrcPtr);
            Inc(CurPos);
            Offset := (CurPos + FileOffset) mod $1000000;
            Move(SrcPtr^, Addr, 4);
            if (Addr and $80000000) <> 0 then
            begin
              if ((Addr + Offset) and $80000000) = 0 then
              begin
                NewAddr := Addr + $1000000;
                Move(NewAddr, SrcPtr^, 4);
              end;
            end
            else
            begin
              // Undo normalisation: apply only when Addr >= 0x1000000.
              // C++: (Addr - 0x1000000) < 0x80000000, i.e. bit-31 is 0.
              if ((Addr - $1000000) and $80000000) = 0 then
              begin
                NewAddr := Addr - Offset;
                Move(NewAddr, SrcPtr^, 4);
              end;
            end;
            Inc(SrcPtr, 4);
            Inc(CurPos, 4);
          end
          else
          begin
            Inc(SrcPtr);
            Inc(CurPos);
          end;
        end;
      end;
    FILTER_ARM:
      begin
        FileOffset := LongWord(FWrittenFileSize);
        CurPos := 0;
        while CurPos + 3 < DataSize do
        begin
          D := Data + CurPos;
          if D[3] = $EB then
          begin
            Offset := LongWord(D[0]) + LongWord(D[1]) * $100 + LongWord(D[2]) * $10000;
            Offset := Offset - (FileOffset + CurPos) div 4;
            D[0] := Byte(Offset);
            D[1] := Byte(Offset shr 8);
            D[2] := Byte(Offset shr 16);
          end;
          Inc(CurPos, 4);
        end;
      end;
    FILTER_DELTA:
      begin
        Channels := Flt^.Channels;
        SrcPos := 0;
        SetLength(FFilterDstMemory, DataSize);
        DstData := @FFilterDstMemory[0];
        for CurChannel := 0 to Channels - 1 do
        begin
          PrevByte := 0;
          DestPos := CurChannel;
          while DestPos < DataSize do
          begin
            Dec(PrevByte, Data[SrcPos]);
            DstData[DestPos] := PrevByte;
            Inc(SrcPos);
            Inc(DestPos, Channels);
          end;
        end;
        Result := DstData;
      end;
  else
    Result := nil;
  end;
end;

procedure TUnpack.InitFilters;
begin
  SetLength(FFilters, 0);
end;

// ── RAR 5.0 ───────────────────────────────────────────────────────────────────

procedure TUnpack.Unpack5(Solid: Boolean);
var
  MainSlot, Length, DBits, DistSlot, LengthSlot, DistNum: LongWord;
  Distance: NativeUInt;
  Filter: TUnpackFilter;
  FileDone: Boolean;
  I: LongWord;
begin
  FFileExtracted := True;
  if not FSuspended then
  begin
    UnpInitData(Solid);
    if not UnpReadBuf then
      Exit;
    if not ReadBlockHeader(FInp, FBlockHeader) or
      not ReadTables(FInp, FBlockHeader, FBlockTables) or
      not FTablesRead5 then
      Exit;
  end;

  while True do
  begin
    FUnpPtr := WrapUp(FUnpPtr);
    FFirstWinDone := FFirstWinDone or (FPrevPtr > FUnpPtr);
    FPrevPtr := FUnpPtr;

    if FInp.InAddr >= FReadBorder then
    begin
      FileDone := False;
      while (FInp.InAddr > FBlockHeader.BlockStart + FBlockHeader.BlockSize - 1) or
        ((FInp.InAddr = FBlockHeader.BlockStart + FBlockHeader.BlockSize - 1) and
        (FInp.InBit >= FBlockHeader.BlockBitSize)) do
      begin
        if FBlockHeader.LastBlockInFile then
        begin
          FileDone := True;
          Break;
        end;
        if not ReadBlockHeader(FInp, FBlockHeader) or
          not ReadTables(FInp, FBlockHeader, FBlockTables) then
          Exit;
      end;
      if FileDone or not UnpReadBuf then
        Break;
    end;

    if (WrapDown(FWriteBorder - FUnpPtr) <= MAX_INC_LZ_MATCH) and
      (FWriteBorder <> FUnpPtr) then
    begin
      UnpWriteBuf;
      if FWrittenFileSize > FDestUnpSize then
        Exit;
      if FSuspended then
      begin
        FFileExtracted := False;
        Exit;
      end;
    end;

    MainSlot := DecodeNumber(FInp, @FBlockTables.LD);

    if MainSlot < 256 then
    begin
      if FFragmented then
        FFragWindow.BytePtr(FUnpPtr)^ := Byte(MainSlot)
      else
        FWindow[FUnpPtr] := Byte(MainSlot);
      Inc(FUnpPtr);
      Continue;
    end;

    if MainSlot >= 262 then
    begin
      Length := SlotToLength(FInp, MainSlot - 262);
      Distance := 1;
      DBits := 0;
      DistSlot := DecodeNumber(FInp, @FBlockTables.DD);
      if DistSlot < 4 then
        Inc(Distance, DistSlot)
      else
      begin
        DBits := DistSlot div 2 - 1;
        Inc(Distance, NativeUInt(2 or (DistSlot and 1)) shl DBits);
      end;
      if DBits > 0 then
      begin
        if DBits >= 4 then
        begin
          if DBits > 4 then
          begin
            if DBits > 36 then
              Inc(Distance, NativeUInt(FInp.getbits64 shr (68 - DBits)) shl 4)
            else
              Inc(Distance, NativeUInt(FInp.getbits32 shr (36 - DBits)) shl 4);
            FInp.addbits(DBits - 4);
          end;
          Inc(Distance, DecodeNumber(FInp, @FBlockTables.LDD));
          if (SizeOf(Distance) = 4) and (DBits >= 30) then
            Distance := NativeUInt(-1);
        end
        else
        begin
          Inc(Distance, FInp.getbits shr (16 - DBits));
          FInp.addbits(DBits);
        end;
      end;
      if Distance > $100 then
      begin
        Inc(Length);
        if Distance > $2000 then
        begin
          Inc(Length);
          if Distance > $40000 then
            Inc(Length);
        end;
      end;
      InsertOldDist(Distance);
      FLastLength := Length;
      if FFragmented then
        FFragWindow.CopyString(Length, Distance, FUnpPtr, FFirstWinDone, MaxWinSize)
      else
        CopyString(Length, Distance);
      Continue;
    end;

    if MainSlot = 256 then
    begin
      if not ReadFilter(FInp, Filter) or not AddFilter(Filter) then
        Break;
      Continue;
    end;

    if MainSlot = 257 then
    begin
      if FLastLength <> 0 then
        if FFragmented then
          FFragWindow.CopyString(FLastLength, FOldDist[0], FUnpPtr, FFirstWinDone, MaxWinSize)
        else
          CopyString(FLastLength, FOldDist[0]);
      Continue;
    end;

    // MainSlot 258..261 — recent distances
    begin
      DistNum := MainSlot - 258;
      Distance := FOldDist[DistNum];
      for I := DistNum downto 1 do
        FOldDist[I] := FOldDist[I - 1];
      FOldDist[0] := Distance;
      LengthSlot := DecodeNumber(FInp, @FBlockTables.RD);
      Length := SlotToLength(FInp, LengthSlot);
      FLastLength := Length;
      if FFragmented then
        FFragWindow.CopyString(Length, Distance, FUnpPtr, FFirstWinDone, MaxWinSize)
      else
        CopyString(Length, Distance);
    end;
  end;
  UnpWriteBuf;
end;

procedure TUnpack.UnpInitData50(Solid: Boolean);
begin
  if not Solid then
    FTablesRead5 := False;
end;

function TUnpack.ReadBlockHeader(AInp: TBitInput; var Header: TUnpackBlockHeader): Boolean;
var
  BlockFlags: Byte;
  ByteCount, I, BlockSize: Integer;
  SavedCheckSum, CheckSum: Byte;
begin
  Result := False;
  Header.HeaderSize := 0;
  if (not AInp.ExternalBuffer) and (AInp.InAddr > FReadTop - 7) then
    if not UnpReadBuf then
      Exit;
  AInp.faddbits((8 - AInp.InBit) and 7);
  BlockFlags := Byte(AInp.fgetbits shr 8);
  AInp.faddbits(8);
  ByteCount := Integer((BlockFlags shr 3) and 3) + 1;
  if ByteCount = 4 then
    Exit;
  Header.HeaderSize := 2 + ByteCount;
  Header.BlockBitSize := Integer(BlockFlags and 7) + 1;
  SavedCheckSum := Byte(AInp.fgetbits shr 8);
  AInp.faddbits(8);
  BlockSize := 0;
  for I := 0 to ByteCount - 1 do
  begin
    Inc(BlockSize, Integer(AInp.fgetbits shr 8) shl (I * 8));
    AInp.addbits(8);
  end;
  Header.BlockSize := BlockSize;
  CheckSum := Byte($5A xor BlockFlags xor Byte(BlockSize) xor
    Byte(BlockSize shr 8) xor Byte(BlockSize shr 16));
  if CheckSum <> SavedCheckSum then
    Exit;
  Header.BlockStart := AInp.InAddr;
  if Header.BlockStart + Header.BlockSize - 1 < FReadBorder then
    FReadBorder := Header.BlockStart + Header.BlockSize - 1;
  Header.LastBlockInFile := (BlockFlags and $40) <> 0;
  Header.TablePresent := (BlockFlags and $80) <> 0;
  Result := True;
end;

function TUnpack.ReadTables(AInp: TBitInput; var Header: TUnpackBlockHeader; var Tables: TUnpackBlockTables): Boolean;
var
  BitLength: array[0..BC - 1] of Byte;
  Table: array[0..HUFF_TABLE_SIZEX - 1] of Byte;
  TableSize, I, N: LongWord;
  Length, ZeroCount, Number: LongWord;
  DCodes: LongWord;
begin
  Result := True;
  if not Header.TablePresent then
    Exit;
  if (not AInp.ExternalBuffer) and (AInp.InAddr > FReadTop - 25) then
    if not UnpReadBuf then
    begin
      Result := False;
      Exit;
    end;

  I := 0;
  while I < BC do
  begin
    Length := Byte(AInp.fgetbits shr 12);
    AInp.faddbits(4);
    if Length = 15 then
    begin
      ZeroCount := Byte(AInp.fgetbits shr 12);
      AInp.faddbits(4);
      if ZeroCount = 0 then
        BitLength[I] := 15
      else
      begin
        Inc(ZeroCount, 2);
        while (ZeroCount > 0) and (I < BC) do
        begin
          BitLength[I] := 0;
          Inc(I);
          Dec(ZeroCount);
        end;
        Dec(I);
      end;
    end
    else
      BitLength[I] := Byte(Length);
    Inc(I);
  end;
  MakeDecodeTables(@BitLength[0], @Tables.BD, BC);

  if ExtraDist then
    TableSize := HUFF_TABLE_SIZEX
  else
    TableSize := HUFF_TABLE_SIZEB;
  I := 0;
  while I < TableSize do
  begin
    if (not AInp.ExternalBuffer) and (AInp.InAddr > FReadTop - 5) then
      if not UnpReadBuf then
      begin
        Result := False;
        Exit;
      end;
    Number := DecodeNumber(AInp, @Tables.BD);
    if Number < 16 then
    begin
      Table[I] := Byte(Number);
      Inc(I);
    end
    else if Number < 18 then
    begin
      if Number = 16 then
      begin
        N := (AInp.fgetbits shr 13) + 3;
        AInp.faddbits(3);
      end
      else
      begin
        N := (AInp.fgetbits shr 9) + 11;
        AInp.faddbits(7);
      end;
      if I = 0 then
      begin
        Result := False;
        Exit;
      end;
      while (N > 0) and (I < TableSize) do
      begin
        Table[I] := Table[I - 1];
        Inc(I);
        Dec(N);
      end;
    end
    else
    begin
      if Number = 18 then
      begin
        N := (AInp.fgetbits shr 13) + 3;
        AInp.faddbits(3);
      end
      else
      begin
        N := (AInp.fgetbits shr 9) + 11;
        AInp.faddbits(7);
      end;
      while (N > 0) and (I < TableSize) do
      begin
        Table[I] := 0;
        Inc(I);
        Dec(N);
      end;
    end;
  end;
  FTablesRead5 := True;
  if (not AInp.ExternalBuffer) and (AInp.InAddr > FReadTop) then
  begin
    Result := False;
    Exit;
  end;
  MakeDecodeTables(@Table[0], @Tables.LD, NC);
  if ExtraDist then
    DCodes := DCX
  else
    DCodes := DCB;
  MakeDecodeTables(@Table[NC], @Tables.DD, DCodes);
  MakeDecodeTables(@Table[NC + DCodes], @Tables.LDD, LDC);
  MakeDecodeTables(@Table[NC + DCodes + LDC], @Tables.RD, RC);
end;

function TUnpack.ReadFilterData(AInp: TBitInput): LongWord;
var
  ByteCount, I, Data: LongWord;
begin
  ByteCount := (AInp.fgetbits shr 14) + 1;
  AInp.addbits(2);
  Data := 0;
  for I := 0 to ByteCount - 1 do
  begin
    Inc(Data, (AInp.fgetbits shr 8) shl (I * 8));
    AInp.addbits(8);
  end;
  Result := Data;
end;

function TUnpack.ReadFilter(AInp: TBitInput; var Filter: TUnpackFilter): Boolean;
begin
  Result := False;
  if (not AInp.ExternalBuffer) and (AInp.InAddr > FReadTop - 16) then
    if not UnpReadBuf then
      Exit;
  Filter.BlockStart := ReadFilterData(AInp);
  Filter.BlockLength := ReadFilterData(AInp);
  if Filter.BlockLength > MAX_FILTER_BLOCK_SIZE then
    Filter.BlockLength := 0;
  Filter.FilterType := Byte(AInp.fgetbits shr 13);
  AInp.faddbits(3);
  if Filter.FilterType = FILTER_DELTA then
  begin
    Filter.Channels := Byte((AInp.fgetbits shr 11) + 1);
    AInp.faddbits(5);
  end;
  Result := True;
end;

function TUnpack.AddFilter(var Filter: TUnpackFilter): Boolean;
begin
  if Length(FFilters) >= MAX_UNPACK_FILTERS then
  begin
    UnpWriteBuf;
    if Length(FFilters) >= MAX_UNPACK_FILTERS then
      InitFilters;
  end;
  Filter.NextWindow :=
    (FWrPtr <> FUnpPtr) and
    (WrapDown(FWrPtr - FUnpPtr) <= Filter.BlockStart);
  Filter.BlockStart := (Filter.BlockStart + FUnpPtr) mod MaxWinSize;
  SetLength(FFilters, Length(FFilters) + 1);
  FFilters[High(FFilters)] := Filter;
  Result := True;
end;

// ── RAR 3.0 ───────────────────────────────────────────────────────────────────

procedure TUnpack.Unpack29(Solid: Boolean);
var
  Dist, BitLength, Slot, I, J: Integer;
  Number, Bits: LongWord;
  Length: LongWord;
  Distance: LongWord;
  DistNumber: LongWord;
  LowDist: LongWord;
  PPMCh, PPMK: Integer;
  PPMFailed: Boolean;
  DistNum29, LengthNum29, K29: LongWord;
begin
  if not Unp29DDecodeInited then
  begin
    Dist := 0;
    BitLength := 0;
    Slot := 0;
    for I := 0 to 18 do
    begin
      for J := 0 to DBitLengthCounts[I] - 1 do
      begin
        Unp29DDecode[Slot] := Dist;
        Unp29DBits[Slot] := Byte(BitLength);
        Inc(Slot);
        Inc(Dist, 1 shl BitLength);
      end;
      Inc(BitLength);
    end;
    Unp29DDecodeInited := True;
  end;

  FFileExtracted := True;
  if not FSuspended then
  begin
    UnpInitData(Solid);
    if not UnpReadBuf30 then
      Exit;
    if (not Solid or not FTablesRead3) and not ReadTables30 then
      Exit;
  end;

  while True do
  begin
    FUnpPtr := FUnpPtr and MaxWinMask;
    FFirstWinDone := FFirstWinDone or (FPrevPtr > FUnpPtr);
    FPrevPtr := FUnpPtr;

    if FInp.InAddr > FReadBorder then
      if not UnpReadBuf30 then
        Break;

    if (((FWrPtr - FUnpPtr) and MaxWinMask) <= MAX3_INC_LZ_MATCH) and
      (FWrPtr <> FUnpPtr) then
    begin
      UnpWriteBuf30;
      if FWrittenFileSize > FDestUnpSize then
        Exit;
      if FSuspended then
      begin
        FFileExtracted := False;
        Exit;
      end;
    end;

    if FUnpBlockType = BLOCK_PPM then
    begin
      I := FPPM.DecodeChar;
      if I = -1 then
      begin
        FPPM.CleanUp;
        FUnpBlockType := BLOCK_LZ;
        Break;
      end;
      if I = FPPMEscChar then
      begin
        I := SafePPMDecodeChar;
        if I = 0 then
        begin
          if not ReadTables30 then
            Break;
          Continue;
        end;
        if I = -1 then
          Break;
        if I = 2 then
          Break;
        if I = 3 then
        begin
          if not ReadVMCodePPM then
            Break;
          Continue;
        end;
        if I = 4 then
        begin
          Distance := 0;
          Length := 0;
          PPMFailed := False;
          for PPMK := 0 to 3 do
          begin
            if PPMFailed then
              Break;
            PPMCh := SafePPMDecodeChar;
            if PPMCh = -1 then
              PPMFailed := True
            else if PPMK = 3 then
              Length := Byte(PPMCh)
            else
              Distance := (Distance shl 8) + Byte(PPMCh);
          end;
          if PPMFailed then
            Break;
          CopyString(Length + 32, Distance + 2);
          Continue;
        end;
        if I = 5 then
        begin
          I := SafePPMDecodeChar;
          if I = -1 then
            Break;
          CopyString(LongWord(I) + 4, 1);
          Continue;
        end;
        // I=1 means literal escape char
      end;
      FWindow[FUnpPtr] := Byte(I);
      Inc(FUnpPtr);
      Continue;
    end;

    Number := DecodeNumber(FInp, @FBlockTables.LD);
    if Number < 256 then
    begin
      FWindow[FUnpPtr] := Byte(Number);
      Inc(FUnpPtr);
      Continue;
    end;
    if Number >= 271 then
    begin
      Dec(Number, 271);
      Length := LDecode29[Number] + 3;
      Bits := LBits29[Number];
      if Bits > 0 then
      begin
        Inc(Length, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      DistNumber := DecodeNumber(FInp, @FBlockTables.DD);
      Distance := LongWord(Unp29DDecode[DistNumber]) + 1;
      Bits := Unp29DBits[DistNumber];
      if Bits > 0 then
      begin
        if DistNumber > 9 then
        begin
          if Bits > 4 then
          begin
            Inc(Distance, (FInp.getbits shr (20 - Bits)) shl 4);
            FInp.addbits(Bits - 4);
          end;
          if FLowDistRepCount > 0 then
          begin
            Dec(FLowDistRepCount);
            Inc(Distance, LongWord(FPrevLowDist));
          end
          else
          begin
            LowDist := DecodeNumber(FInp, @FBlockTables.LDD);
            if LowDist = 16 then
            begin
              FLowDistRepCount := LOW_DIST_REP_COUNT - 1;
              Inc(Distance, LongWord(FPrevLowDist));
            end
            else
            begin
              Inc(Distance, LowDist);
              FPrevLowDist := Integer(LowDist);
            end;
          end;
        end
        else
        begin
          Inc(Distance, FInp.getbits shr (16 - Bits));
          FInp.addbits(Bits);
        end;
      end;
      if Distance >= $2000 then
      begin
        Inc(Length);
        if Distance >= $40000 then
          Inc(Length);
      end;
      InsertOldDist(Distance);
      FLastLength := Length;
      CopyString(Length, Distance);
      Continue;
    end;
    if Number = 256 then
    begin
      if not ReadEndOfBlock then
        Break;
      Continue;
    end;
    if Number = 257 then
    begin
      if not ReadVMCode then
        Break;
      Continue;
    end;
    if Number = 258 then
    begin
      if FLastLength <> 0 then
        CopyString(FLastLength, LongWord(FOldDist[0]));
      Continue;
    end;
    if Number < 263 then
    begin
      DistNum29 := Number - 259;
      Distance := LongWord(FOldDist[DistNum29]);
      for K29 := DistNum29 downto 1 do
        FOldDist[K29] := FOldDist[K29 - 1];
      FOldDist[0] := Distance;
      LengthNum29 := DecodeNumber(FInp, @FBlockTables.RD);
      Length := LDecode29[LengthNum29] + 2;
      Bits := LBits29[LengthNum29];
      if Bits > 0 then
      begin
        Inc(Length, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      FLastLength := Length;
      CopyString(Length, Distance);
      Continue;
    end;
    if Number < 272 then
    begin
      Dec(Number, 263);
      Distance := SDDecode[Number] + 1;
      Bits := SDBits[Number];
      if Bits > 0 then
      begin
        Inc(Distance, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      InsertOldDist(Distance);
      FLastLength := 2;
      CopyString(2, Distance);
      Continue;
    end;
  end;
  UnpWriteBuf30;
end;

procedure TUnpack.UnpInitData30(Solid: Boolean);
begin
  if not Solid then
  begin
    FTablesRead3 := False;
    FillChar(FUnpOldTable, SizeOf(FUnpOldTable), 0);
    FPPMEscChar := 2;
    FUnpBlockType := BLOCK_LZ;
  end;
  InitFilters30(Solid);
end;

procedure TUnpack.InitFilters30(Solid: Boolean);
var
  I: Integer;
begin
  if not Solid then
  begin
    SetLength(FOldFilterLengths, 0);
    FLastFilter := 0;
    for I := 0 to High(FFilters30) do
      if FFilters30[I] <> nil then
      begin
        Dispose(FFilters30[I]);
        FFilters30[I] := nil;
      end;
    SetLength(FFilters30, 0);
  end;
  for I := 0 to High(FPrgStack) do
    if FPrgStack[I] <> nil then
    begin
      Dispose(FPrgStack[I]);
      FPrgStack[I] := nil;
    end;
  SetLength(FPrgStack, 0);
end;

function TUnpack.ReadEndOfBlock: Boolean;
var
  BitField: LongWord;
  NewTable, NewFile: Boolean;
begin
  BitField := FInp.getbits;
  NewFile := False;
  if (BitField and $8000) <> 0 then
  begin
    NewTable := True;
    FInp.addbits(1);
  end
  else
  begin
    NewFile := True;
    NewTable := (BitField and $4000) <> 0;
    FInp.addbits(2);
  end;
  FTablesRead3 := not NewTable;
  if NewFile then
  begin
    Result := False;
    Exit;
  end;
  Result := ReadTables30;
end;

function TUnpack.ReadVMCode: Boolean;
var
  FirstByte, Length, I: LongWord;
  VMCode: array of Byte;
begin
  Result := False;
  FirstByte := FInp.getbits shr 8;
  FInp.addbits(8);
  Length := (FirstByte and 7) + 1;
  if Length = 7 then
  begin
    Length := (FInp.getbits shr 8) + 7;
    FInp.addbits(8);
  end
  else if Length = 8 then
  begin
    Length := FInp.getbits;
    FInp.addbits(16);
  end;
  if Length = 0 then
    Exit;
  SetLength(VMCode, Length);
  for I := 0 to Length - 1 do
  begin
    if (FInp.InAddr >= FReadTop - 1) and not UnpReadBuf30 and (I < Length - 1) then
      Exit;
    VMCode[I] := Byte(FInp.getbits shr 8);
    FInp.addbits(8);
  end;
  Result := AddVMCode(FirstByte, @VMCode[0], Length);
end;

function TUnpack.ReadVMCodePPM: Boolean;
var
  FirstByte, Length, I: LongWord;
  B1, B2: Integer;
  VMCode: array of Byte;
  Ch: Integer;
begin
  Result := False;
  FirstByte := LongWord(SafePPMDecodeChar);
  if Integer(FirstByte) = -1 then
    Exit;
  Length := (FirstByte and 7) + 1;
  if Length = 7 then
  begin
    B1 := SafePPMDecodeChar;
    if B1 = -1 then
      Exit;
    Length := LongWord(B1) + 7;
  end
  else if Length = 8 then
  begin
    B1 := SafePPMDecodeChar;
    if B1 = -1 then
      Exit;
    B2 := SafePPMDecodeChar;
    if B2 = -1 then
      Exit;
    Length := LongWord(B1) * 256 + LongWord(B2);
  end;
  if Length = 0 then
    Exit;
  SetLength(VMCode, Length);
  for I := 0 to Length - 1 do
  begin
    Ch := SafePPMDecodeChar;
    if Ch = -1 then
      Exit;
    VMCode[I] := Byte(Ch);
  end;
  Result := AddVMCode(FirstByte, @VMCode[0], Length);
end;

function TUnpack.AddVMCode(FirstByte: LongWord; Code: PByte; CodeSize: LongWord): Boolean;
var
  FiltPos: LongWord;
  NewFilter: Boolean;
  StackFilter, Filter: PUnpackFilter30;
  EmptyCount, I: Integer;
  StackPos: Integer;
  BlockStart: LongWord;
  InitMask, VMCodeSize: LongWord;
  VMCode: array of Byte;
begin
  Result := False;
  FVMCodeInp.InitBitInput;
  if CodeSize > 0 then
  begin
    if CodeSize > BITINPUT_MAX_SIZE then
      Move(Code^, FVMCodeInp.InBuf^, BITINPUT_MAX_SIZE)
    else
      Move(Code^, FVMCodeInp.InBuf^, CodeSize);
  end;
  FVM.Init;

  if (FirstByte and $80) <> 0 then
  begin
    FiltPos := TRarVM.ReadData(FVMCodeInp);
    if FiltPos = 0 then
      InitFilters30(False)
    else
      Dec(FiltPos);
  end
  else
    FiltPos := LongWord(FLastFilter);

  if (FiltPos > LongWord(Length(FFilters30))) or
    (FiltPos > LongWord(Length(FOldFilterLengths))) then
    Exit;
  FLastFilter := Integer(FiltPos);
  NewFilter := (FiltPos = LongWord(Length(FFilters30)));

  New(StackFilter);
  FillChar(StackFilter^, SizeOf(TUnpackFilter30), 0);

  if NewFilter then
  begin
    if FiltPos > MAX3_UNPACK_FILTERS then
    begin
      Dispose(StackFilter);
      Exit;
    end;
    StackFilter^.ParentFilter := LongWord(Length(FFilters30));
    New(Filter);
    FillChar(Filter^, SizeOf(TUnpackFilter30), 0);
    SetLength(FFilters30, Length(FFilters30) + 1);
    FFilters30[High(FFilters30)] := Filter;
    SetLength(FOldFilterLengths, Length(FOldFilterLengths) + 1);
    FOldFilterLengths[High(FOldFilterLengths)] := 0;
  end
  else
  begin
    Filter := FFilters30[FiltPos];
    StackFilter^.ParentFilter := FiltPos;
  end;

  // Compact nil slots in PrgStack
  EmptyCount := 0;
  for I := 0 to High(FPrgStack) do
  begin
    FPrgStack[I - EmptyCount] := FPrgStack[I];
    if FPrgStack[I] = nil then
      Inc(EmptyCount);
    if EmptyCount > 0 then
      FPrgStack[I] := nil;
  end;
  if EmptyCount = 0 then
  begin
    if Length(FPrgStack) > MAX3_UNPACK_FILTERS then
    begin
      Dispose(StackFilter);
      Exit;
    end;
    SetLength(FPrgStack, Length(FPrgStack) + 1);
    EmptyCount := 1;
  end;
  StackPos := Length(FPrgStack) - EmptyCount;
  FPrgStack[StackPos] := StackFilter;

  BlockStart := TRarVM.ReadData(FVMCodeInp);
  if (FirstByte and $40) <> 0 then
    Inc(BlockStart, 258);
  StackFilter^.BlockStart := (BlockStart + LongWord(FUnpPtr)) and LongWord(MaxWinMask);
  if (FirstByte and $20) <> 0 then
  begin
    StackFilter^.BlockLength := TRarVM.ReadData(FVMCodeInp);
    FOldFilterLengths[FiltPos] := Integer(StackFilter^.BlockLength);
  end
  else
  begin
    if FiltPos < LongWord(Length(FOldFilterLengths)) then
      StackFilter^.BlockLength := LongWord(FOldFilterLengths[FiltPos])
    else
      StackFilter^.BlockLength := 0;
  end;

  StackFilter^.NextWindow :=
    (FWrPtr <> FUnpPtr) and
    ((LongWord(FWrPtr - FUnpPtr) and LongWord(MaxWinMask)) <= BlockStart);

  FillChar(StackFilter^.Prg.InitR, SizeOf(StackFilter^.Prg.InitR), 0);
  StackFilter^.Prg.InitR[4] := StackFilter^.BlockLength;

  if (FirstByte and $10) <> 0 then
  begin
    InitMask := FVMCodeInp.fgetbits shr 9;
    FVMCodeInp.faddbits(7);
    for I := 0 to 6 do
      if (InitMask and (1 shl I)) <> 0 then
        StackFilter^.Prg.InitR[I] := TRarVM.ReadData(FVMCodeInp);
  end;

  if NewFilter then
  begin
    VMCodeSize := TRarVM.ReadData(FVMCodeInp);
    if (VMCodeSize >= $10000) or (VMCodeSize = 0) or
      (FVMCodeInp.InAddr < 0) or (UInt64(FVMCodeInp.InAddr) + VMCodeSize > CodeSize) then
      Exit;
    SetLength(VMCode, VMCodeSize);
    for I := 0 to Integer(VMCodeSize) - 1 do
    begin
      if FVMCodeInp.Overflow(3) then
        Exit;
      VMCode[I] := Byte(FVMCodeInp.fgetbits shr 8);
      FVMCodeInp.faddbits(8);
    end;
    FVM.Prepare(@VMCode[0], VMCodeSize, @Filter^.Prg);
  end;
  StackFilter^.Prg.FilterType := Filter^.Prg.FilterType;
  Result := True;
end;

function TUnpack.SafePPMDecodeChar: Integer;
begin
  Result := FPPM.DecodeChar;
  if Result = -1 then
  begin
    FPPM.CleanUp;
    FUnpBlockType := BLOCK_LZ;
  end;
end;

function TUnpack.ReadTables30: Boolean;
var
  BitLength: array[0..BC30 - 1] of Byte;
  Table: array[0..HUFF_TABLE_SIZE30 - 1] of Byte;
  I, N: LongWord;
  BitField, Length, ZeroCount, Number: LongWord;
begin
  Result := False;
  if FInp.InAddr > FReadTop - 25 then
    if not UnpReadBuf30 then
      Exit;
  FInp.faddbits((8 - FInp.InBit) and 7);
  BitField := FInp.fgetbits;
  if (BitField and $8000) <> 0 then
  begin
    FUnpBlockType := BLOCK_PPM;
    Result := FPPM.DecodeInit(Self, FPPMEscChar);
    Exit;
  end;
  FUnpBlockType := BLOCK_LZ;
  FPrevLowDist := 0;
  FLowDistRepCount := 0;
  if (BitField and $4000) = 0 then
    FillChar(FUnpOldTable, SizeOf(FUnpOldTable), 0);
  FInp.faddbits(2);

  I := 0;
  while I < BC30 do
  begin
    Length := Byte(FInp.fgetbits shr 12);
    FInp.faddbits(4);
    if Length = 15 then
    begin
      ZeroCount := Byte(FInp.fgetbits shr 12);
      FInp.faddbits(4);
      if ZeroCount = 0 then
        BitLength[I] := 15
      else
      begin
        Inc(ZeroCount, 2);
        while (ZeroCount > 0) and (I < BC30) do
        begin
          BitLength[I] := 0;
          Inc(I);
          Dec(ZeroCount);
        end;
        // I already points past last filled slot; the outer Inc(I) at end
        // of this iteration would skip one — so undo one advance.
        Dec(I);
      end;
    end
    else
      BitLength[I] := Byte(Length);
    Inc(I);
  end;
  MakeDecodeTables(@BitLength[0], @FBlockTables.BD, BC30);

  I := 0;
  while I < HUFF_TABLE_SIZE30 do
  begin
    if FInp.InAddr > FReadTop - 5 then
      if not UnpReadBuf30 then
        Exit;
    Number := DecodeNumber(FInp, @FBlockTables.BD);
    if Number < 16 then
    begin
      Table[I] := Byte((Number + FUnpOldTable[I]) and $F);
      Inc(I);
    end
    else if Number < 18 then
    begin
      if Number = 16 then
      begin
        N := (FInp.fgetbits shr 13) + 3;
        FInp.faddbits(3);
      end
      else
      begin
        N := (FInp.fgetbits shr 9) + 11;
        FInp.faddbits(7);
      end;
      if I = 0 then
        Exit;
      while (N > 0) and (I < HUFF_TABLE_SIZE30) do
      begin
        Table[I] := Table[I - 1];
        Inc(I);
        Dec(N);
      end;
    end
    else
    begin
      if Number = 18 then
      begin
        N := (FInp.fgetbits shr 13) + 3;
        FInp.faddbits(3);
      end
      else
      begin
        N := (FInp.fgetbits shr 9) + 11;
        FInp.faddbits(7);
      end;
      while (N > 0) and (I < HUFF_TABLE_SIZE30) do
      begin
        Table[I] := 0;
        Inc(I);
        Dec(N);
      end;
    end;
  end;
  FTablesRead3 := True;
  if FInp.InAddr > FReadTop then
    Exit;
  MakeDecodeTables(@Table[0], @FBlockTables.LD, NC30);
  MakeDecodeTables(@Table[NC30], @FBlockTables.DD, DC30);
  MakeDecodeTables(@Table[NC30 + DC30], @FBlockTables.LDD, LDC30);
  MakeDecodeTables(@Table[NC30 + DC30 + LDC30], @FBlockTables.RD, RC30);
  Move(Table, FUnpOldTable, SizeOf(FUnpOldTable));
  Result := True;
end;

function TUnpack.UnpReadBuf30: Boolean;
var
  DataSize, ReadCode: Integer;
begin
  DataSize := FReadTop - FInp.InAddr;
  if DataSize < 0 then
  begin
    Result := False;
    Exit;
  end;
  if FInp.InAddr > BITINPUT_MAX_SIZE div 2 then
  begin
    if DataSize > 0 then
      Move(FInp.InBuf[FInp.InAddr], FInp.InBuf[0], DataSize);
    FInp.InAddr := 0;
    FReadTop := DataSize;
  end
  else
    DataSize := FReadTop;
  ReadCode := UnpIO.UnpRead(FInp.InBuf + DataSize, BITINPUT_MAX_SIZE - DataSize);
  if ReadCode > 0 then
    Inc(FReadTop, ReadCode);
  FReadBorder := FReadTop - 30;
  Result := (ReadCode <> -1);
end;

procedure TUnpack.UnpWriteBuf30;
var
  WrittenBorder, WriteSize, BlockStart, BlockLength, BlockEnd: LongWord;
  FirstPartLen: LongWord;
  I, J: Integer;
  Flt, NextFlt: PUnpackFilter30;
  FilteredData: PByte;
  FilteredDataSize: LongWord;
begin
  WrittenBorder := LongWord(FWrPtr);
  WriteSize := LongWord((FUnpPtr - WrittenBorder) and MaxWinMask);

  I := 0;
  while I < Length(FPrgStack) do
  begin
    Flt := FPrgStack[I];
    if Flt = nil then
    begin
      Inc(I);
      Continue;
    end;
    if Flt^.NextWindow then
    begin
      Flt^.NextWindow := False;
      Inc(I);
      Continue;
    end;
    BlockStart := Flt^.BlockStart;
    BlockLength := Flt^.BlockLength;
    if ((BlockStart - WrittenBorder) and LongWord(MaxWinMask)) < WriteSize then
    begin
      if WrittenBorder <> BlockStart then
      begin
        UnpWriteArea(WrittenBorder, BlockStart);
        WrittenBorder := BlockStart;
        WriteSize := LongWord((FUnpPtr - WrittenBorder) and MaxWinMask);
      end;
      if BlockLength <= WriteSize then
      begin
        BlockEnd := (BlockStart + BlockLength) and LongWord(MaxWinMask);
        if (BlockStart < BlockEnd) or (BlockEnd = 0) then
          FVM.SetMemory(0, FWindow + BlockStart, BlockLength)
        else
        begin
          FirstPartLen := LongWord(MaxWinSize) - BlockStart;
          FVM.SetMemory(0, FWindow + BlockStart, FirstPartLen);
          FVM.SetMemory(FirstPartLen, FWindow, BlockEnd);
        end;
        ExecuteCode(@Flt^.Prg);
        FilteredData := Flt^.Prg.FilteredData;
        FilteredDataSize := Flt^.Prg.FilteredDataSize;
        Dispose(FPrgStack[I]);
        FPrgStack[I] := nil;

        // Chain filters on same block
        while I + 1 < Length(FPrgStack) do
        begin
          NextFlt := FPrgStack[I + 1];
          if (NextFlt = nil) or
            (NextFlt^.BlockStart <> BlockStart) or
            (NextFlt^.BlockLength <> FilteredDataSize) or
            NextFlt^.NextWindow then
            Break;
          FVM.SetMemory(0, FilteredData, FilteredDataSize);
          ExecuteCode(@NextFlt^.Prg);
          FilteredData := NextFlt^.Prg.FilteredData;
          FilteredDataSize := NextFlt^.Prg.FilteredDataSize;
          Inc(I);
          Dispose(FPrgStack[I]);
          FPrgStack[I] := nil;
        end;

        UnpIO.UnpWrite(FilteredData, FilteredDataSize);
        FUnpSomeRead := True;
        Inc(FWrittenFileSize, FilteredDataSize);
        WrittenBorder := BlockEnd;
        WriteSize := LongWord((FUnpPtr - WrittenBorder) and LongWord(MaxWinMask));
      end
      else
      begin
        for J := I to High(FPrgStack) do
          if (FPrgStack[J] <> nil) and FPrgStack[J]^.NextWindow then
            FPrgStack[J]^.NextWindow := False;
        FWrPtr := WrittenBorder;
        Exit;
      end;
    end;
    Inc(I);
  end;
  UnpWriteArea(WrittenBorder, FUnpPtr);
  FWrPtr := FUnpPtr;
end;

procedure TUnpack.ExecuteCode(Prg: PVM_PreparedProgram);
begin
  Prg^.InitR[6] := LongWord(FWrittenFileSize);
  FVM.Execute(Prg);
end;

// ── RAR 2.0 ───────────────────────────────────────────────────────────────────

procedure TUnpack.Unpack20(Solid: Boolean);
var
  Number, Bits, Length, DistNumber, Distance: LongWord;
  LengthNumber: LongWord;
begin
  if FSuspended then
    FUnpPtr := FWrPtr
  else
  begin
    UnpInitData(Solid);
    if not UnpReadBuf then
      Exit;
    if (not Solid or not FTablesRead2) and not ReadTables20 then
      Exit;
    Dec(FDestUnpSize);
  end;

  while FDestUnpSize >= 0 do
  begin
    FUnpPtr := FUnpPtr and MaxWinMask;
    FFirstWinDone := FFirstWinDone or (FPrevPtr > FUnpPtr);
    FPrevPtr := FUnpPtr;

    if FInp.InAddr > FReadTop - 30 then
      if not UnpReadBuf then
        Break;
    if (((FWrPtr - FUnpPtr) and MaxWinMask) < 270) and (FWrPtr <> FUnpPtr) then
    begin
      UnpWriteBuf20;
      if FSuspended then
        Exit;
    end;

    if FUnpAudioBlock then
    begin
      Number := DecodeNumber(FInp, @FMD[FUnpCurChannel]);
      if Number = 256 then
      begin
        if not ReadTables20 then
          Break;
        Continue;
      end;
      FWindow[FUnpPtr] := DecodeAudio(Integer(Number));
      Inc(FUnpPtr);
      Inc(FUnpCurChannel);
      if FUnpCurChannel = FUnpChannels then
        FUnpCurChannel := 0;
      Dec(FDestUnpSize);
      Continue;
    end;

    Number := DecodeNumber(FInp, @FBlockTables.LD);
    if Number < 256 then
    begin
      FWindow[FUnpPtr] := Byte(Number);
      Inc(FUnpPtr);
      Dec(FDestUnpSize);
      Continue;
    end;
    if Number > 269 then
    begin
      Dec(Number, 270);
      Length := LDecode29[Number] + 3;
      Bits := LBits29[Number];
      if Bits > 0 then
      begin
        Inc(Length, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      DistNumber := DecodeNumber(FInp, @FBlockTables.DD);
      Distance := DDecode20[DistNumber] + 1;
      Bits := DBits20[DistNumber];
      if Bits > 0 then
      begin
        Inc(Distance, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      if Distance >= $2000 then
      begin
        Inc(Length);
        if Distance >= $40000 then
          Inc(Length);
      end;
      CopyString20(Length, Distance);
      Continue;
    end;
    if Number = 269 then
    begin
      if not ReadTables20 then
        Break;
      Continue;
    end;
    if Number = 256 then
    begin
      CopyString20(FLastLength, FLastDist);
      Continue;
    end;
    if Number < 261 then
    begin
      Distance := LongWord(FOldDist[(FOldDistPtr - (Number - 256)) and 3]);
      LengthNumber := DecodeNumber(FInp, @FBlockTables.RD);
      Length := LDecode29[LengthNumber] + 2;
      Bits := LBits29[LengthNumber];
      if Bits > 0 then
      begin
        Inc(Length, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      if Distance >= $101 then
      begin
        Inc(Length);
        if Distance >= $2000 then
        begin
          Inc(Length);
          if Distance >= $40000 then
            Inc(Length);
        end;
      end;
      CopyString20(Length, Distance);
      Continue;
    end;
    if Number < 270 then
    begin
      Dec(Number, 261);
      Distance := SDDecode[Number] + 1;
      Bits := SDBits[Number];
      if Bits > 0 then
      begin
        Inc(Distance, FInp.getbits shr (16 - Bits));
        FInp.addbits(Bits);
      end;
      CopyString20(2, Distance);
      Continue;
    end;
  end;
  ReadLastTables;
  UnpWriteBuf20;
end;

procedure TUnpack.UnpInitData20(Solid: Boolean);
begin
  if not Solid then
  begin
    FTablesRead2 := False;
    FUnpAudioBlock := False;
    FUnpChannelDelta := 0;
    FUnpCurChannel := 0;
    FUnpChannels := 1;
    FillChar(FAudV, SizeOf(FAudV), 0);
    FillChar(FUnpOldTable20, SizeOf(FUnpOldTable20), 0);
    FillChar(FMD, SizeOf(FMD), 0);
  end;
end;

procedure TUnpack.CopyString20(ALength, Distance: LongWord);
begin
  FLastDist := Distance;
  FOldDist[FOldDistPtr] := Distance;
  Inc(FOldDistPtr);
  FOldDistPtr := FOldDistPtr and 3;
  FLastLength := ALength;
  Dec(FDestUnpSize, ALength);
  CopyString(ALength, Distance);
end;

function TUnpack.ReadTables20: Boolean;
var
  BitLength: array[0..BC20 - 1] of Byte;
  Table: array[0..MC20 * 4 - 1] of Byte;
  BitField, TableSize, I, N: LongWord;
  Number: LongWord;
begin
  Result := False;
  if FInp.InAddr > FReadTop - 25 then
    if not UnpReadBuf then
      Exit;
  BitField := FInp.getbits;
  FUnpAudioBlock := (BitField and $8000) <> 0;
  if (BitField and $4000) = 0 then
    FillChar(FUnpOldTable20, SizeOf(FUnpOldTable20), 0);
  FInp.addbits(2);
  if FUnpAudioBlock then
  begin
    FUnpChannels := ((BitField shr 12) and 3) + 1;
    if FUnpCurChannel >= FUnpChannels then
      FUnpCurChannel := 0;
    FInp.addbits(2);
    TableSize := MC20 * FUnpChannels;
  end
  else
    TableSize := NC20 + DC20 + RC20;

  for I := 0 to BC20 - 1 do
  begin
    BitLength[I] := Byte(FInp.getbits shr 12);
    FInp.addbits(4);
  end;
  MakeDecodeTables(@BitLength[0], @FBlockTables.BD, BC20);

  I := 0;
  while I < TableSize do
  begin
    if FInp.InAddr > FReadTop - 5 then
      if not UnpReadBuf then
        Exit;
    Number := DecodeNumber(FInp, @FBlockTables.BD);
    if Number < 16 then
    begin
      Table[I] := Byte((Number + FUnpOldTable20[I]) and $F);
      Inc(I);
    end
    else if Number = 16 then
    begin
      N := (FInp.getbits shr 14) + 3;
      FInp.addbits(2);
      if I = 0 then
        Exit;
      while (N > 0) and (I < TableSize) do
      begin
        Table[I] := Table[I - 1];
        Inc(I);
        Dec(N);
      end;
    end
    else
    begin
      if Number = 17 then
      begin
        N := (FInp.getbits shr 13) + 3;
        FInp.addbits(3);
      end
      else
      begin
        N := (FInp.getbits shr 9) + 11;
        FInp.addbits(7);
      end;
      while (N > 0) and (I < TableSize) do
      begin
        Table[I] := 0;
        Inc(I);
        Dec(N);
      end;
    end;
  end;
  FTablesRead2 := True;
  if FInp.InAddr > FReadTop then
  begin
    Result := True;
    Exit; // return true even if slightly over
  end;
  if FUnpAudioBlock then
  begin
    for I := 0 to FUnpChannels - 1 do
      MakeDecodeTables(@Table[I * MC20], @FMD[I], MC20);
  end
  else
  begin
    MakeDecodeTables(@Table[0], @FBlockTables.LD, NC20);
    MakeDecodeTables(@Table[NC20], @FBlockTables.DD, DC20);
    MakeDecodeTables(@Table[NC20 + DC20], @FBlockTables.RD, RC20);
  end;
  Move(Table, FUnpOldTable20, TableSize);
  Result := True;
end;

procedure TUnpack.UnpWriteBuf20;
begin
  if FUnpPtr <> FWrPtr then
    FUnpSomeRead := True;
  if FUnpPtr < FWrPtr then
  begin
    UnpIO.UnpWrite(FWindow + FWrPtr, MaxWinSize - FWrPtr);
    UnpIO.UnpWrite(FWindow, FUnpPtr);
  end
  else
    UnpIO.UnpWrite(FWindow + FWrPtr, FUnpPtr - FWrPtr);
  FWrPtr := FUnpPtr;
end;

procedure TUnpack.ReadLastTables;
begin
  if (FInp.InAddr >= 0) and (FReadTop >= 5) and (FInp.InAddr <= FReadTop - 5) then
    if FUnpAudioBlock then
    begin
      if DecodeNumber(FInp, @FMD[FUnpCurChannel]) = 256 then
        ReadTables20;
    end
    else
    begin
      if DecodeNumber(FInp, @FBlockTables.LD) = 269 then
        ReadTables20;
    end;
end;

function TUnpack.DecodeAudio(Delta: Integer): Byte;
var
  V: ^TAudioVariables;
  PCh, D: Integer;
  Ch: LongWord;
  MinDif: LongWord;
  NumMinDif: LongWord;
  I: Integer;
begin
  V := @FAudV[FUnpCurChannel];
  Inc(V^.ByteCount);
  V^.D4 := V^.D3;
  V^.D3 := V^.D2;
  V^.D2 := V^.LastDelta - V^.D1;
  V^.D1 := V^.LastDelta;
  PCh := 8 * V^.LastChar + V^.K1 * V^.D1 + V^.K2 * V^.D2 +
    V^.K3 * V^.D3 + V^.K4 * V^.D4 + V^.K5 * FUnpChannelDelta;
  PCh := (PCh shr 3) and $FF;
  Ch := LongWord(PCh) - LongWord(Delta);
  D := ShortInt(Delta);
  D := Integer(LongWord(D) shl 3);
  Inc(V^.Dif[0], LongWord(Abs(D)));
  Inc(V^.Dif[1], LongWord(Abs(D - V^.D1)));
  Inc(V^.Dif[2], LongWord(Abs(D + V^.D1)));
  Inc(V^.Dif[3], LongWord(Abs(D - V^.D2)));
  Inc(V^.Dif[4], LongWord(Abs(D + V^.D2)));
  Inc(V^.Dif[5], LongWord(Abs(D - V^.D3)));
  Inc(V^.Dif[6], LongWord(Abs(D + V^.D3)));
  Inc(V^.Dif[7], LongWord(Abs(D - V^.D4)));
  Inc(V^.Dif[8], LongWord(Abs(D + V^.D4)));
  Inc(V^.Dif[9], LongWord(Abs(D - FUnpChannelDelta)));
  Inc(V^.Dif[10], LongWord(Abs(D + FUnpChannelDelta)));
  FUnpChannelDelta := ShortInt(Ch - LongWord(V^.LastChar));
  V^.LastDelta := FUnpChannelDelta;
  V^.LastChar := Integer(Ch);
  if (V^.ByteCount and $1F) = 0 then
  begin
    MinDif := V^.Dif[0];
    NumMinDif := 0;
    V^.Dif[0] := 0;
    for I := 1 to 10 do
    begin
      if V^.Dif[I] < MinDif then
      begin
        MinDif := V^.Dif[I];
        NumMinDif := LongWord(I);
      end;
      V^.Dif[I] := 0;
    end;
    case NumMinDif of
      1:
        if V^.K1 >= -16 then
          Dec(V^.K1);
      2:
        if V^.K1 < 16 then
          Inc(V^.K1);
      3:
        if V^.K2 >= -16 then
          Dec(V^.K2);
      4:
        if V^.K2 < 16 then
          Inc(V^.K2);
      5:
        if V^.K3 >= -16 then
          Dec(V^.K3);
      6:
        if V^.K3 < 16 then
          Inc(V^.K3);
      7:
        if V^.K4 >= -16 then
          Dec(V^.K4);
      8:
        if V^.K4 < 16 then
          Inc(V^.K4);
      9:
        if V^.K5 >= -16 then
          Dec(V^.K5);
      10:
        if V^.K5 < 16 then
          Inc(V^.K5);
    end;
  end;
  Result := Byte(Ch);
end;

// ── RAR 1.5 ───────────────────────────────────────────────────────────────────

procedure TUnpack.Unpack15(Solid: Boolean);
begin
  UnpInitData(Solid);
  UnpInitData15(Solid);
  UnpReadBuf;
  if not Solid then
  begin
    InitHuff;
    FUnpPtr := 0;
  end
  else
    FUnpPtr := FWrPtr;
  Dec(FDestUnpSize);
  if FDestUnpSize >= 0 then
  begin
    GetFlagsBuf;
    FFlagsCnt := 8;
  end;

  while FDestUnpSize >= 0 do
  begin
    FUnpPtr := FUnpPtr and MaxWinMask;
    FFirstWinDone := FFirstWinDone or (FPrevPtr > FUnpPtr);
    FPrevPtr := FUnpPtr;
    if (FInp.InAddr > FReadTop - 30) and not UnpReadBuf then
      Break;
    if (((FWrPtr - FUnpPtr) and MaxWinMask) < 270) and (FWrPtr <> FUnpPtr) then
      UnpWriteBuf20;
    if FStMode <> 0 then
    begin
      HuffDecode;
      Continue;
    end;
    Dec(FFlagsCnt);
    if FFlagsCnt < 0 then
    begin
      GetFlagsBuf;
      FFlagsCnt := 7;
    end;
    if (FFlagBuf and $80) <> 0 then
    begin
      FFlagBuf := FFlagBuf shl 1;
      if FNlzb > FNhfb then
        LongLZ
      else
        HuffDecode;
    end
    else
    begin
      FFlagBuf := FFlagBuf shl 1;
      Dec(FFlagsCnt);
      if FFlagsCnt < 0 then
      begin
        GetFlagsBuf;
        FFlagsCnt := 7;
      end;
      if (FFlagBuf and $80) <> 0 then
      begin
        FFlagBuf := FFlagBuf shl 1;
        if FNlzb > FNhfb then
          HuffDecode
        else
          LongLZ;
      end
      else
      begin
        FFlagBuf := FFlagBuf shl 1;
        ShortLZ;
      end;
    end;
  end;
  UnpWriteBuf20;
end;

procedure TUnpack.UnpInitData15(Solid: Boolean);
begin
  if not Solid then
  begin
    FAvrPlcB := 0;
    FAvrLn1 := 0;
    FAvrLn2 := 0;
    FAvrLn3 := 0;
    FNumHuf := 0;
    FBuf60 := 0;
    FAvrPlc := $3500;
    FMaxDist3 := $2001;
    FNhfb := $80;
    FNlzb := $80;
  end;
  FFlagsCnt := 0;
  FFlagBuf := 0;
  FStMode := 0;
  FLCount := 0;
  FReadTop := 0;
end;

procedure TUnpack.InitHuff;
var
  I: Word;
begin
  for I := 0 to 255 do
  begin
    FChSet[I] := Word(I) shl 8;
    FChSetB[I] := Word(I) shl 8;
    FChSetA[I] := I;
    FChSetC[I] := Word((($100 - I) and $FF) shl 8);
  end;
  FillChar(FNToPl, SizeOf(FNToPl), 0);
  FillChar(FNToPlB, SizeOf(FNToPlB), 0);
  FillChar(FNToPlC, SizeOf(FNToPlC), 0);
  CorrHuff(@FChSetB[0], @FNToPlB[0]);
end;

procedure TUnpack.CorrHuff(CharSet: PWord; NumToPlace: PByte);
var
  I, J: Integer;
begin
  for I := 7 downto 0 do
    for J := 0 to 31 do
    begin
      CharSet^ := (CharSet^ and $FF00) or Word(I);
      Inc(CharSet);
    end;
  FillChar(NumToPlace^, 256, 0);
  for I := 6 downto 0 do
    NumToPlace[I] := Byte((7 - I) * 32);
end;

procedure TUnpack.ShortLZ;
var
  Length, SaveLength, LastDistance, Distance: LongWord;
  DistancePlace: Integer;
  BitField: LongWord;
  L: LongWord;
begin
  FNumHuf := 0;
  BitField := FInp.fgetbits;
  if FLCount = 2 then
  begin
    FInp.faddbits(1);
    if BitField >= $8000 then
    begin
      CopyString15(FLastDist, FLastLength);
      Exit;
    end;
    BitField := BitField shl 1;
    FLCount := 0;
  end;
  BitField := BitField shr 8;

  if FAvrLn1 < 37 then
  begin
    for Length := 0 to 14 do
    begin
      if Length = 1 then
        L := LongWord(FBuf60) + 3
      else
        L := ShortLen1[Length];
      if ((BitField xor ShortXor1[Length]) and (not ($FF shr L))) = 0 then
        Break;
    end;
    if Length = 1 then
      FInp.faddbits(LongWord(FBuf60) + 3)
    else
      FInp.faddbits(ShortLen1[Length]);
  end
  else
  begin
    for Length := 0 to 14 do
    begin
      if Length = 3 then
        L := LongWord(FBuf60) + 3
      else
        L := ShortLen2[Length];
      if ((BitField xor ShortXor2[Length]) and (not ($FF shr L))) = 0 then
        Break;
    end;
    if Length = 3 then
      FInp.faddbits(LongWord(FBuf60) + 3)
    else
      FInp.faddbits(ShortLen2[Length]);
  end;

  if Length >= 9 then
  begin
    if Length = 9 then
    begin
      Inc(FLCount);
      CopyString15(FLastDist, FLastLength);
      Exit;
    end;
    if Length = 14 then
    begin
      FLCount := 0;
      Length := DecodeNum(FInp.fgetbits, STARTL2, @DecL2[0], @PosL2[0]) + 5;
      Distance := (FInp.fgetbits shr 1) or $8000;
      FInp.faddbits(15);
      FLastLength := Length;
      FLastDist := Distance;
      CopyString15(Distance, Length);
      Exit;
    end;
    FLCount := 0;
    SaveLength := Length;
    Distance := LongWord(FOldDist[(FOldDistPtr - (Length - 9)) and 3]);
    Length := DecodeNum(FInp.fgetbits, STARTL1, @DecL1[0], @PosL1[0]) + 2;
    if (Length = $101) and (SaveLength = 10) then
    begin
      FBuf60 := FBuf60 xor 1;
      Exit;
    end;
    if Distance > 256 then
      Inc(Length);
    if Distance >= FMaxDist3 then
      Inc(Length);
    FOldDist[FOldDistPtr] := Distance;
    Inc(FOldDistPtr);
    FOldDistPtr := FOldDistPtr and 3;
    FLastLength := Length;
    FLastDist := Distance;
    CopyString15(Distance, Length);
    Exit;
  end;

  FLCount := 0;
  Inc(FAvrLn1, Length);
  FAvrLn1 := FAvrLn1 - (FAvrLn1 shr 4);
  DistancePlace := Integer(
    DecodeNum(FInp.fgetbits, STARTHF2, @DecHf2[0], @PosHf2[0]) and $FF);
  Distance := FChSetA[DistancePlace];
  if DistancePlace > 0 then
  begin
    LastDistance := FChSetA[DistancePlace - 1];
    FChSetA[DistancePlace] := Word(LastDistance);
    FChSetA[DistancePlace - 1] := Word(Distance);
  end;
  Inc(Length, 2);
  Inc(Distance);
  FOldDist[FOldDistPtr] := Distance;
  Inc(FOldDistPtr);
  FOldDistPtr := FOldDistPtr and 3;
  FLastLength := Length;
  FLastDist := Distance;
  CopyString15(Distance, Length);
end;

procedure TUnpack.LongLZ;
var
  Length, Distance, DistancePlace, NewDistancePlace: LongWord;
  OldAvr2, OldAvr3: LongWord;
  BitField: LongWord;
begin
  FNumHuf := 0;
  Inc(FNlzb, 16);
  if FNlzb > $FF then
  begin
    FNlzb := $90;
    FNhfb := FNhfb shr 1;
  end;
  OldAvr2 := FAvrLn2;
  BitField := FInp.fgetbits;
  if FAvrLn2 >= 122 then
    Length := DecodeNum(BitField, STARTL2, @DecL2[0], @PosL2[0])
  else if FAvrLn2 >= 64 then
    Length := DecodeNum(BitField, STARTL1, @DecL1[0], @PosL1[0])
  else if BitField < $100 then
  begin
    Length := BitField;
    FInp.faddbits(16);
  end
  else
  begin
    Length := 0;
    while ((BitField shl Length) and $8000) = 0 do
      Inc(Length);
    FInp.faddbits(Length + 1);
  end;
  Inc(FAvrLn2, Length);
  FAvrLn2 := FAvrLn2 - (FAvrLn2 shr 5);
  BitField := FInp.fgetbits;
  if FAvrPlcB > $28FF then
    DistancePlace := DecodeNum(BitField, STARTHF2, @DecHf2[0], @PosHf2[0])
  else if FAvrPlcB > $6FF then
    DistancePlace := DecodeNum(BitField, STARTHF1, @DecHf1[0], @PosHf1[0])
  else
    DistancePlace := DecodeNum(BitField, STARTHF0, @DecHf0[0], @PosHf0[0]);
  Inc(FAvrPlcB, DistancePlace);
  FAvrPlcB := FAvrPlcB - (FAvrPlcB shr 8);
  repeat
    Distance := FChSetB[DistancePlace and $FF];
    NewDistancePlace := FNToPlB[Distance and $FF];
    Inc(FNToPlB[Distance and $FF]);
    Inc(Distance);
    if (Distance and $FF) = 0 then
      CorrHuff(@FChSetB[0], @FNToPlB[0])
    else
      Break;
  until False;
  FChSetB[DistancePlace and $FF] := FChSetB[NewDistancePlace];
  FChSetB[NewDistancePlace] := Word(Distance);
  Distance := ((Distance and $FF00) or (FInp.fgetbits shr 8)) shr 1;
  FInp.faddbits(7);
  OldAvr3 := FAvrLn3;
  if (Length <> 1) and (Length <> 4) then
    if (Length = 0) and (Distance <= FMaxDist3) then
    begin
      Inc(FAvrLn3);
      FAvrLn3 := FAvrLn3 - (FAvrLn3 shr 8);
    end
    else if FAvrLn3 > 0 then
      Dec(FAvrLn3);
  Inc(Length, 3);
  if Distance >= FMaxDist3 then
    Inc(Length);
  if Distance <= 256 then
    Inc(Length, 8);
  if (OldAvr3 > $B0) or ((FAvrPlc >= $2A00) and (OldAvr2 < $40)) then
    FMaxDist3 := $7F00
  else
    FMaxDist3 := $2001;
  FOldDist[FOldDistPtr] := Distance;
  Inc(FOldDistPtr);
  FOldDistPtr := FOldDistPtr and 3;
  FLastLength := Length;
  FLastDist := Distance;
  CopyString15(Distance, Length);
end;

procedure TUnpack.HuffDecode;
var
  CurByte, NewBytePlace: LongWord;
  BytePlace: Integer;
  Length, Distance: LongWord;
  BitField: LongWord;
begin
  BitField := FInp.fgetbits;
  if FAvrPlc > $75FF then
    BytePlace := Integer(DecodeNum(BitField, STARTHF4, @DecHf4[0], @PosHf4[0]))
  else if FAvrPlc > $5DFF then
    BytePlace := Integer(DecodeNum(BitField, STARTHF3, @DecHf3[0], @PosHf3[0]))
  else if FAvrPlc > $35FF then
    BytePlace := Integer(DecodeNum(BitField, STARTHF2, @DecHf2[0], @PosHf2[0]))
  else if FAvrPlc > $0DFF then
    BytePlace := Integer(DecodeNum(BitField, STARTHF1, @DecHf1[0], @PosHf1[0]))
  else
    BytePlace := Integer(DecodeNum(BitField, STARTHF0, @DecHf0[0], @PosHf0[0]));
  BytePlace := BytePlace and $FF;

  if FStMode <> 0 then
  begin
    if (BytePlace = 0) and (BitField > $FFF) then
      BytePlace := $100;
    Dec(BytePlace);
    if BytePlace = -1 then
    begin
      BitField := FInp.fgetbits;
      FInp.faddbits(1);
      if (BitField and $8000) <> 0 then
      begin
        FNumHuf := 0;
        FStMode := 0;
        Exit;
      end
      else
      begin
        if (BitField and $4000) <> 0 then
          Length := 4
        else
          Length := 3;
        FInp.faddbits(1);
        Distance := DecodeNum(FInp.fgetbits, STARTHF2, @DecHf2[0], @PosHf2[0]);
        Distance := (Distance shl 5) or (FInp.fgetbits shr 11);
        FInp.faddbits(5);
        CopyString15(Distance, Length);
        Exit;
      end;
    end;
  end
  else
  begin
    if (FNumHuf >= 16) and (FFlagsCnt = 0) then
      FStMode := 1;
    Inc(FNumHuf);
  end;

  Inc(FAvrPlc, LongWord(BytePlace));
  FAvrPlc := FAvrPlc - (FAvrPlc shr 8);
  Inc(FNhfb, 16);
  if FNhfb > $FF then
  begin
    FNhfb := $90;
    FNlzb := FNlzb shr 1;
  end;

  FWindow[FUnpPtr] := Byte(FChSet[BytePlace] shr 8);
  Inc(FUnpPtr);
  Dec(FDestUnpSize);

  repeat
    CurByte := FChSet[BytePlace];
    NewBytePlace := FNToPl[CurByte and $FF];
    Inc(FNToPl[CurByte and $FF]);
    Inc(CurByte);
    if (CurByte and $FF) > $A1 then
      CorrHuff(@FChSet[0], @FNToPl[0])
    else
      Break;
  until False;
  FChSet[BytePlace] := Word(FChSet[NewBytePlace]);
  FChSet[NewBytePlace] := Word(CurByte);
end;

procedure TUnpack.GetFlagsBuf;
var
  FlagsPlace: LongWord;
  Flags, NewFlagsPlace: LongWord;
begin
  FlagsPlace := DecodeNum(FInp.fgetbits, STARTHF2, @DecHf2[0], @PosHf2[0]);
  if FlagsPlace >= 256 then
    Exit;
  repeat
    Flags := FChSetC[FlagsPlace];
    FFlagBuf := Flags shr 8;
    NewFlagsPlace := FNToPlC[Flags and $FF];
    Inc(FNToPlC[Flags and $FF]);
    Inc(Flags);
    if (Flags and $FF) <> 0 then
      Break;
    CorrHuff(@FChSetC[0], @FNToPlC[0]);
  until False;
  FChSetC[FlagsPlace] := Word(FChSetC[NewFlagsPlace]);
  FChSetC[NewFlagsPlace] := Word(Flags);
end;

procedure TUnpack.CopyString15(Distance, ALength: LongWord);
begin
  Dec(FDestUnpSize, ALength);
  if (not FFirstWinDone and (Distance > FUnpPtr)) or
    (Distance > MaxWinSize) or (Distance = 0) then
    while ALength > 0 do
    begin
      FWindow[FUnpPtr] := 0;
      FUnpPtr := (FUnpPtr + 1) and MaxWinMask;
      Dec(ALength);
    end
  else
    while ALength > 0 do
    begin
      FWindow[FUnpPtr] := FWindow[(FUnpPtr - Distance) and MaxWinMask];
      FUnpPtr := (FUnpPtr + 1) and MaxWinMask;
      Dec(ALength);
    end;
end;

function TUnpack.DecodeNum(Num, StartPos: LongWord; DecTab, PosTab: PLongWord): LongWord;
var
  I: Integer;
begin
  Num := Num and $FFF0;
  I := 0;
  while DecTab[I] <= Num do
  begin
    Inc(StartPos);
    Inc(I);
  end;
  FInp.faddbits(StartPos);
  if I > 0 then
    Result := ((Num - DecTab[I - 1]) shr (16 - StartPos)) + PosTab[StartPos]
  else
    Result := (Num shr (16 - StartPos)) + PosTab[StartPos];
end;

end.

