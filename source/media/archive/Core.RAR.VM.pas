unit Core.RAR.VM;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
{$POINTERMATH ON}

// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

//  TRarVM — RAR virtual machine used for RAR 3.x filters
//  (rarvm.hpp / rarvm.cpp)
//  Only standard filters are implemented (E8, E8E9, Itanium, Delta, RGB, Audio).

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  Core.RAR.Types, Core.RAR.GetBits;

type
  TRarVM = class
  private
    FMem: PByte;                     // 256 KB virtual memory
    FR: array[0..7] of LongWord;   // registers R0..R7

    function ExecuteStandardFilter(AType: TVMStandardFilter): Boolean;
    function GetBits(Data: PByte; BitPos, BitCount: LongWord): LongWord;
    procedure SetBits(Data: PByte; BitField, BitPos, BitCount: LongWord);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Init;
    // Identify filter type from its bytecode CRC.
    procedure Prepare(Code: PByte; CodeSize: LongWord; Prg: PVM_PreparedProgram);
    procedure Execute(Prg: PVM_PreparedProgram);
    procedure SetMemory(Pos: NativeUInt; Data: PByte; DataSize: NativeUInt);
    class function ReadData(Inp: TBitInput): LongWord;
  end;

implementation

uses
  SysUtils;

// ─────────────────────────────────────────────────────────────────────────────

constructor TRarVM.Create;
begin
  FMem := nil;
end;

destructor TRarVM.Destroy;
begin
  FreeMem(FMem);
  inherited;
end;

procedure TRarVM.Init;
begin
  if FMem = nil then
    GetMem(FMem, VM_MEMSIZE + 4);
end;

// ── ReadData ────────────────────────────────────────────────────────────────

class function TRarVM.ReadData(Inp: TBitInput): LongWord;
var
  Data: LongWord;
begin
  Data := Inp.fgetbits;
  case Data and $C000 of
    0:
      begin
        Inp.faddbits(6);
        Result := (Data shr 10) and $F;
      end;
    $4000:
      begin
        if (Data and $3C00) = 0 then
        begin
          Data := $FFFFFF00 or ((Data shr 2) and $FF);
          Inp.faddbits(14);
        end
        else
        begin
          Data := (Data shr 6) and $FF;
          Inp.faddbits(10);
        end;
        Result := Data;
      end;
    $8000:
      begin
        Inp.faddbits(2);
        Data := Inp.fgetbits;
        Inp.faddbits(16);
        Result := Data;
      end;
  else // $C000
    begin
      Inp.faddbits(2);
      Data := Inp.fgetbits shl 16;
      Inp.faddbits(16);
      Data := Data or Inp.fgetbits;
      Inp.faddbits(16);
      Result := Data;
    end;
  end;
end;

// ── Prepare — identify standard filter by CRC ──────────────────────────────

procedure TRarVM.Prepare(Code: PByte; CodeSize: LongWord; Prg: PVM_PreparedProgram);
type
  TStdFilter = record
    Len: LongWord;
    CRC: LongWord;
    Typ: TVMStandardFilter;
  end;
const
  StdList: array[0..5] of TStdFilter = (
    (Len: 53; CRC: $AD576887; Typ: VMSF_E8),
    (Len: 57; CRC: $3CD7E57E; Typ: VMSF_E8E9),
    (Len: 120; CRC: $3769893F; Typ: VMSF_ITANIUM),
    (Len: 29; CRC: $0E06077D; Typ: VMSF_DELTA),
    (Len: 149; CRC: $1C2C5DC8; Typ: VMSF_RGB),
    (Len: 216; CRC: $BC85E701; Typ: VMSF_AUDIO)
  );
var
  XorSum: Byte;
  CRC32Val: LongWord;
  I, J: Integer;
  CRCTable: array[0..255] of LongWord;
  B: Byte;
begin
  Prg^.FilterType := VMSF_NONE;
  if CodeSize = 0 then
    Exit;

  // Verify XOR checksum of bytecode.
  XorSum := 0;
  for I := 1 to Integer(CodeSize) - 1 do
    XorSum := XorSum xor Code[I];
  if XorSum <> Code[0] then
    Exit;

  // Build CRC32 table and compute CRC of bytecode.
  for I := 0 to 255 do
  begin
    CRC32Val := LongWord(I);
    for J := 0 to 7 do
      if (CRC32Val and 1) <> 0 then
        CRC32Val := (CRC32Val shr 1) xor $EDB88320
      else
        CRC32Val := CRC32Val shr 1;
    CRCTable[I] := CRC32Val;
  end;
  CRC32Val := $FFFFFFFF;
  for I := 0 to Integer(CodeSize) - 1 do
  begin
    B := Code[I];
    CRC32Val := CRCTable[(CRC32Val xor B) and $FF] xor (CRC32Val shr 8);
  end;
  CRC32Val := CRC32Val xor $FFFFFFFF;

  for I := 0 to High(StdList) do
    if (StdList[I].CRC = CRC32Val) and (StdList[I].Len = CodeSize) then
    begin
      Prg^.FilterType := StdList[I].Typ;
      Break;
    end;
end;

// ── Execute ─────────────────────────────────────────────────────────────────

procedure TRarVM.Execute(Prg: PVM_PreparedProgram);
var
  BlockSize: LongWord;
begin
  Move(Prg^.InitR[0], FR[0], SizeOf(Prg^.InitR));
  Prg^.FilteredData := nil;
  if Prg^.FilterType <> VMSF_NONE then
  begin
    ExecuteStandardFilter(Prg^.FilterType);
    BlockSize := FR[4] and VM_MEMMASK;
    Prg^.FilteredDataSize := BlockSize;
    if Prg^.FilterType in [VMSF_DELTA, VMSF_RGB, VMSF_AUDIO] then
    begin
      if (2 * BlockSize > VM_MEMSIZE) or not ExecuteStandardFilter(Prg^.FilterType) then
        Prg^.FilteredData := FMem
      else
        Prg^.FilteredData := FMem + BlockSize;
    end
    else
      Prg^.FilteredData := FMem;
  end;
end;

// ── SetMemory ────────────────────────────────────────────────────────────────

procedure TRarVM.SetMemory(Pos: NativeUInt; Data: PByte; DataSize: NativeUInt);
var
  CopySize: NativeUInt;
begin
  if (Pos < VM_MEMSIZE) and (Data <> FMem + Pos) then
  begin
    CopySize := DataSize;
    if CopySize > VM_MEMSIZE - Pos then
      CopySize := VM_MEMSIZE - Pos;
    if CopySize > 0 then
      Move(Data^, (FMem + Pos)^, CopySize);
  end;
end;

// ── Standard filter implementations ─────────────────────────────────────────

function TRarVM.GetBits(Data: PByte; BitPos, BitCount: LongWord): LongWord;
var
  InAddr, InBit, BitField: LongWord;
begin
  InAddr := BitPos shr 3;
  InBit := BitPos and 7;
  BitField := LongWord(Data[InAddr])
    or (LongWord(Data[InAddr + 1]) shl 8)
    or (LongWord(Data[InAddr + 2]) shl 16)
    or (LongWord(Data[InAddr + 3]) shl 24);
  BitField := BitField shr InBit;
  Result := BitField and (LongWord($FFFFFFFF) shr (32 - BitCount));
end;

procedure TRarVM.SetBits(Data: PByte; BitField, BitPos, BitCount: LongWord);
var
  InAddr, InBit, AndMask, I: LongWord;
begin
  InAddr := BitPos shr 3;
  InBit := BitPos and 7;
  AndMask := LongWord($FFFFFFFF) shr (32 - BitCount);
  AndMask := not (AndMask shl InBit);
  BitField := BitField shl InBit;
  for I := 0 to 3 do
  begin
    Data[InAddr + I] := Byte(Data[InAddr + I] and (AndMask and $FF));
    Data[InAddr + I] := Byte(Data[InAddr + I] or (BitField and $FF));
    AndMask := (AndMask shr 8) or $FF000000;
    BitField := BitField shr 8;
  end;
end;

function TRarVM.ExecuteStandardFilter(AType: TVMStandardFilter): Boolean;
var
  Data: PByte;
  DataSize, FileOffset, FileSize: LongWord;
  CmpByte2: Byte;
  CurPos, Offset, Addr: LongWord;
  // Itanium
  Byte0, CmdMask, I, StartPos, OpType: LongWord;
  IMasks: array[0..15] of Byte;
  // Delta
  Channels, SrcPos, Border, CurChannel: LongWord;
  PrevByte: Byte;
  DestPos: LongWord;
  // RGB
  Width, PosR, Channels3: LongWord;
  SrcData, DestData: PByte;
  UpperData: PByte;
  UpperByte, UpperLeftByte, Predicted: LongWord;
  pa, pb, pc: Integer;
  G: Byte;
  // Audio
  AChannels, ByteCount: LongWord;
  PrevByteA, PrevDelta: LongWord;
  Dif: array[0..6] of LongWord;
  D1, D2, D3: Integer;
  K1, K2, K3: Integer;
  CurByte: LongWord;
  D, MinDif, NumMinDif, J: LongWord;
  PredictedA: LongWord;
begin
  Result := True;
  case AType of

    VMSF_E8, VMSF_E8E9:
      begin
        Data := FMem;
        DataSize := FR[4];
        FileOffset := FR[6];
        if (DataSize > VM_MEMSIZE) or (DataSize < 4) then
          Exit(False);
        FileSize := $1000000;
        if AType = VMSF_E8E9 then
          CmpByte2 := $E9
        else
          CmpByte2 := $E8;
        CurPos := 0;
        while CurPos + 4 < DataSize do
        begin
          if (Data[0] = $E8) or (Data[0] = CmpByte2) then
          begin
            Offset := (CurPos + 1 + FileOffset) mod FileSize;
            Addr := LongWord(Data[1])
              or (LongWord(Data[2]) shl 8)
              or (LongWord(Data[3]) shl 16)
              or (LongWord(Data[4]) shl 24);
            if (Addr and $80000000) <> 0 then  // Addr < 0
            begin
              if ((Addr + Offset) and $80000000) = 0 then  // Addr+Offset >= 0
              begin
                Addr := Addr + FileSize;
                Data[1] := Byte(Addr);
                Data[2] := Byte(Addr shr 8);
                Data[3] := Byte(Addr shr 16);
                Data[4] := Byte(Addr shr 24);
              end;
            end
            else
            begin
              if ((Addr - FileSize) and $80000000) <> 0 then // Addr < FileSize
              begin
                Addr := Addr - Offset;
                Data[1] := Byte(Addr);
                Data[2] := Byte(Addr shr 8);
                Data[3] := Byte(Addr shr 16);
                Data[4] := Byte(Addr shr 24);
              end;
            end;
            Inc(Data, 4);
            Inc(CurPos, 4);
          end;
          Inc(Data);
          Inc(CurPos);
        end;
      end;
    VMSF_ITANIUM:
      begin
        Data := FMem;
        DataSize := FR[4];
        FileOffset := FR[6];
        if (DataSize > VM_MEMSIZE) or (DataSize < 21) then
          Exit(False);
        CurPos := 0;
        FileOffset := FileOffset shr 4;
        IMasks[0] := 4;
        IMasks[1] := 4;
        IMasks[2] := 6;
        IMasks[3] := 6;
        IMasks[4] := 0;
        IMasks[5] := 0;
        IMasks[6] := 7;
        IMasks[7] := 7;
        IMasks[8] := 4;
        IMasks[9] := 4;
        IMasks[10] := 0;
        IMasks[11] := 0;
        IMasks[12] := 4;
        IMasks[13] := 4;
        IMasks[14] := 0;
        IMasks[15] := 0;
        while CurPos + 21 <= DataSize do
        begin
          Byte0 := LongWord(Data[0] and $1F) - $10;
          if Byte0 <= $F then
          begin
            CmdMask := IMasks[Byte0];
            if CmdMask <> 0 then
              for I := 0 to 2 do
                if (CmdMask and (1 shl I)) <> 0 then
                begin
                  StartPos := I * 41 + 5;
                  OpType := GetBits(Data, StartPos + 37, 4);
                  if OpType = 5 then
                  begin
                    Offset := GetBits(Data, StartPos + 13, 20);
                    SetBits(Data, (Offset - FileOffset) and $FFFFF, StartPos + 13, 20);
                  end;
                end;
          end;
          Inc(Data, 16);
          Inc(CurPos, 16);
          Inc(FileOffset);
        end;
      end;
    VMSF_DELTA:
      begin
        DataSize := FR[4];
        Channels := FR[0];
        SrcPos := 0;
        Border := DataSize * 2;
        if (DataSize > VM_MEMSIZE div 2) or (Channels > MAX3_UNPACK_CHANNELS)
          or (Channels = 0) then
          Exit(False);
        for CurChannel := 0 to Channels - 1 do
        begin
          PrevByte := 0;
          DestPos := DataSize + CurChannel;
          while DestPos < Border do
          begin
            PrevByte := Byte(PrevByte - FMem[SrcPos]);
            FMem[DestPos] := PrevByte;
            Inc(SrcPos);
            Inc(DestPos, Channels);
          end;
        end;
      end;
    VMSF_RGB:
      begin
        DataSize := FR[4];
        Width := FR[0] - 3;
        PosR := FR[1];
        if (DataSize > VM_MEMSIZE div 2) or (DataSize < 3)
          or (Width > DataSize) or (PosR > 2) then
          Exit(False);
        SrcData := FMem;
        DestData := SrcData + DataSize;
        Channels3 := 3;
        for CurChannel := 0 to 2 do
        begin
          PrevByteA := 0;
          I := CurChannel;
          while I < DataSize do
          begin
            if I >= Width + 3 then
            begin
              UpperData := DestData + I - Width;
              UpperByte := UpperData[0];
              UpperLeftByte := UpperData[-3];  // pointer arithmetic, {$POINTERMATH ON} assumed
              Predicted := PrevByteA + UpperByte - UpperLeftByte;
              pa := Abs(Integer(Predicted) - Integer(PrevByteA));
              pb := Abs(Integer(Predicted) - Integer(UpperByte));
              pc := Abs(Integer(Predicted) - Integer(UpperLeftByte));
              if (pa <= pb) and (pa <= pc) then
                Predicted := PrevByteA
              else if pb <= pc then
                Predicted := UpperByte
              else
                Predicted := UpperLeftByte;
            end
            else
              Predicted := PrevByteA;
            PrevByteA := (Predicted - SrcData[0]) and $FF;
            DestData[I] := Byte(PrevByteA);
            Inc(SrcData);
            Inc(I, Channels3);
          end;
        end;
        I := PosR;
        while I + 2 < DataSize do
        begin
          G := DestData[I + 1];
          DestData[I] := Byte(DestData[I] + G);
          DestData[I + 2] := Byte(DestData[I + 2] + G);
          Inc(I, 3);
        end;
      end;
    VMSF_AUDIO:
      begin
        DataSize := FR[4];
        AChannels := FR[0];
        SrcData := FMem;
        DestData := SrcData + DataSize;
        if (DataSize > VM_MEMSIZE div 2) or (AChannels > 128) or (AChannels = 0) then
          Exit(False);
        for CurChannel := 0 to AChannels - 1 do
        begin
          PrevByteA := 0;
          PrevDelta := 0;
          FillChar(Dif, SizeOf(Dif), 0);
          D1 := 0;
          D2 := 0;
          K1 := 0;
          K2 := 0;
          K3 := 0;
          ByteCount := 0;
          I := CurChannel;
          while I < DataSize do
          begin
            D3 := D2;
            D2 := Integer(PrevDelta) - D1;
            D1 := Integer(PrevDelta);
            PredictedA := 8 * PrevByteA
              + LongWord(K1 * D1 + K2 * D2 + K3 * D3);
            PredictedA := (PredictedA shr 3) and $FF;
            CurByte := SrcData[0];
            Inc(SrcData);
            PredictedA := (PredictedA - CurByte) and $FF;
            DestData[I] := Byte(PredictedA);
            PrevDelta := LongWord(ShortInt(PredictedA - PrevByteA));
            PrevByteA := PredictedA;
            D := LongWord(ShortInt(CurByte)) shl 3;
            Dif[0] := Dif[0] + LongWord(Abs(Integer(D)));
            Dif[1] := Dif[1] + LongWord(Abs(Integer(D) - D1));
            Dif[2] := Dif[2] + LongWord(Abs(Integer(D) + D1));
            Dif[3] := Dif[3] + LongWord(Abs(Integer(D) - D2));
            Dif[4] := Dif[4] + LongWord(Abs(Integer(D) + D2));
            Dif[5] := Dif[5] + LongWord(Abs(Integer(D) - D3));
            Dif[6] := Dif[6] + LongWord(Abs(Integer(D) + D3));
            if (ByteCount and $1F) = 0 then
            begin
              MinDif := Dif[0];
              Dif[0] := 0;
              NumMinDif := 0;
              for J := 1 to 6 do
              begin
                if Dif[J] < MinDif then
                begin
                  MinDif := Dif[J];
                  NumMinDif := J;
                end;
                Dif[J] := 0;
              end;
              case NumMinDif of
                1:
                  if K1 >= -16 then
                    Dec(K1);
                2:
                  if K1 < 16 then
                    Inc(K1);
                3:
                  if K2 >= -16 then
                    Dec(K2);
                4:
                  if K2 < 16 then
                    Inc(K2);
                5:
                  if K3 >= -16 then
                    Dec(K3);
                6:
                  if K3 < 16 then
                    Inc(K3);
              end;
            end;
            Inc(I, AChannels);
            Inc(ByteCount);
          end;
        end;
      end;
  end; // case
end;

end.

