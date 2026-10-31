unit PS2.SIF.Bridge;

// The SIF hardware between the EE and the IOP when both run their own
// kernels (BIOS boot): the mailbox registers (MSCOM, SMCOM, MSFLG, SMFLG,
// CTRL, BD6) at 1000F200h on the EE and 1D000000h on the IOP, and the SIF0
// (IOP to EE) and SIF1 (EE to IOP) FIFOs between EE DMA channels 5/6 and IOP
// DMA channels 9/10.
// SIF0 carries, per IOP chain element, the EE DMAtag the IOP sends after its
// own tag (one quadword) and the element's words padded to whole quadwords,
// so EE channel 5 reads tags and data in quadwords (destination chain).
// SIF1 carries the quadwords of EE channel 6 (after the upper half of each
// DMAtag with CHCR.TTE). IOP channel 10 reads them as elements: a header
// (the IOP tag: address and flags, word count; four words with its CHCR bit
// 8, the last two unused), the words the tag names, and the rest of their
// last quadword. An element may span several EE chain packets.
// References: ps2tek (SIF registers, DMAC chain mode, IOP DMA), ps2sdk
// sifman (AFL 2.0; tag formats and register use).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS2.Types, PS2.DMAC;

const
  // Words a FIFO holds for data (tags may go beyond).
  SIFFIFOWords = 128;

type
  TPS2SIFFIFO = record
    Words: array[0..255] of Cardinal;
    Head, Count: Integer;
    procedure Clear;
    function Room: Integer;
    procedure Push(W: Cardinal);
    function Pop: Cardinal;
  end;

  TPS2SIFBridge = class
  private
    FMSCOM, FSMCOM, FMSFLG, FSMFLG, FEECtrl, FIOPCtrl, FBD6: Cardinal;
  public
    FIFO0, FIFO1: TPS2SIFFIFO;
    // SIF0 got data (EE channel 5 can go on), SIF0 has room (IOP channel 9),
    // SIF1 got data (IOP channel 10), SIF1 has room (EE channel 6).
    OnEEData: TProc;
    OnIOPRoom: TProc;
    OnIOPData: TProc;
    OnEERoom: TProc;
    procedure Reset;
    // Registers by offset from the block (00h MSCOM .. 60h BD6).
    function EERead(Offset: Cardinal): Cardinal;
    procedure EEWrite(Offset, Value: Cardinal);
    function IOPRead(Offset: Cardinal): Cardinal;
    procedure IOPWrite(Offset, Value: Cardinal);
    // IOP channel 9: the EE DMAtag of an element (as one quadword), its
    // words, and the padding after its last word.
    procedure PushTag0(W0, W1: Cardinal);
    procedure Push0(W: Cardinal);
    procedure Pad0;
    // IOP channel 10: the next element's header of Header words (False: not
    // there yet) with its first two words (the IOP tag), and its words.
    function PullTag1(Header: Integer; out W0, W1: Cardinal): Boolean;
    function Pull1(out W: Cardinal): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

  // EE DMA channel 5 (destination chain from SIF0).
  TPS2SIF0Port = class(TPS2DMAPort)
  private
    FBridge: TPS2SIFBridge;
  public
    constructor Create(Bridge: TPS2SIFBridge);
    function Pull(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
  end;

  // EE DMA channel 6 (source chain to SIF1; the DMAtag's upper half goes
  // first).
  TPS2SIF1Port = class(TPS2DMAPort)
  private
    FBridge: TPS2SIFBridge;
  public
    constructor Create(Bridge: TPS2SIFBridge);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    procedure Tag(Channel: Integer; const Tag: TPS2Reg128); override;
  end;

implementation

{ TPS2SIFFIFO }

procedure TPS2SIFFIFO.Clear;
begin
  Head := 0;
  Count := 0;
end;

function TPS2SIFFIFO.Room: Integer;
begin
  Result := SIFFIFOWords - Count;
  if Result < 0 then
    Result := 0;
end;

procedure TPS2SIFFIFO.Push(W: Cardinal);
begin
  if Count > High(Words) then
    Exit;
  Words[(Head + Count) and High(Words)] := W;
  Inc(Count);
end;

function TPS2SIFFIFO.Pop: Cardinal;
begin
  Result := Words[Head];
  Head := (Head + 1) and High(Words);
  Dec(Count);
end;

{ TPS2SIFBridge }

procedure TPS2SIFBridge.Reset;
begin
  FMSCOM := 0;
  FSMCOM := 0;
  FMSFLG := 0;
  FSMFLG := 0;
  FEECtrl := 0;
  FIOPCtrl := 0;
  FBD6 := 0;
  FIFO0.Clear;
  FIFO1.Clear;
end;

// CTRL reads with bit 1 and bits 28-31 set, and bit 8 on the EE side.
function TPS2SIFBridge.EERead(Offset: Cardinal): Cardinal;
begin
  case Offset and $F0 of
    $00: Result := FMSCOM;
    $10: Result := FSMCOM;
    $20: Result := FMSFLG;
    $30: Result := FSMFLG;
    $40: Result := FEECtrl or $F0000102;
    $60: Result := FBD6;
  else
    Result := 0;
  end;
end;

// The EE sets MSFLG bits and clears SMFLG bits.
procedure TPS2SIFBridge.EEWrite(Offset, Value: Cardinal);
begin
  case Offset and $F0 of
    $00: FMSCOM := Value;
    $20: FMSFLG := FMSFLG or Value;
    $30: FSMFLG := FSMFLG and not Value;
    $40: FEECtrl := Value and not Cardinal($F0000102);
    $60: FBD6 := Value;
  end;
end;

function TPS2SIFBridge.IOPRead(Offset: Cardinal): Cardinal;
begin
  case Offset and $F0 of
    $00: Result := FMSCOM;
    $10: Result := FSMCOM;
    $20: Result := FMSFLG;
    $30: Result := FSMFLG;
    $40: Result := FIOPCtrl or $F0000002;
    $60: Result := FBD6;
  else
    Result := 0;
  end;
end;

// The IOP sets SMFLG bits and clears MSFLG bits; CTRL bits 4-7 (SIF0,
// SIF1, SIF2 direction enables as sifman uses them) stay set once written.
procedure TPS2SIFBridge.IOPWrite(Offset, Value: Cardinal);
begin
  case Offset and $F0 of
    $10: FSMCOM := Value;
    $20: FMSFLG := FMSFLG and not Value;
    $30: FSMFLG := FSMFLG or Value;
    $40: FIOPCtrl := FIOPCtrl or (Value and $F0);
    $60: FBD6 := Value;
  end;
end;

procedure TPS2SIFBridge.PushTag0(W0, W1: Cardinal);
begin
  FIFO0.Push(W0);
  FIFO0.Push(W1);
  FIFO0.Push(0);
  FIFO0.Push(0);
  if Assigned(OnEEData) then
    OnEEData();
end;

procedure TPS2SIFBridge.Push0(W: Cardinal);
begin
  FIFO0.Push(W);
  if ((FIFO0.Count and 3) = 0) and Assigned(OnEEData) then
    OnEEData();
end;

procedure TPS2SIFBridge.Pad0;
begin
  while (FIFO0.Count and 3) <> 0 do
    FIFO0.Push(0);
  if Assigned(OnEEData) then
    OnEEData();
end;

function TPS2SIFBridge.PullTag1(Header: Integer; out W0, W1: Cardinal): Boolean;
begin
  Result := FIFO1.Count >= Header;
  if not Result then
    Exit;
  W0 := FIFO1.Pop;
  W1 := FIFO1.Pop;
  for var K := 3 to Header do
    FIFO1.Pop;
  if Assigned(OnEERoom) then
    OnEERoom();
end;

function TPS2SIFBridge.Pull1(out W: Cardinal): Boolean;
begin
  Result := FIFO1.Count > 0;
  if not Result then
    Exit;
  W := FIFO1.Pop;
  if ((FIFO1.Count and 3) = 0) and Assigned(OnEERoom) then
    OnEERoom();
end;

procedure TPS2SIFBridge.SerializeState(State: TStateArchive);
begin
  State.Field(FMSCOM, SizeOf(FMSCOM));
  State.Field(FSMCOM, SizeOf(FSMCOM));
  State.Field(FMSFLG, SizeOf(FMSFLG));
  State.Field(FSMFLG, SizeOf(FSMFLG));
  State.Field(FEECtrl, SizeOf(FEECtrl));
  State.Field(FIOPCtrl, SizeOf(FIOPCtrl));
  State.Field(FBD6, SizeOf(FBD6));
  State.Field(FIFO0, SizeOf(FIFO0));
  State.Field(FIFO1, SizeOf(FIFO1));
end;

{ TPS2SIF0Port }

constructor TPS2SIF0Port.Create(Bridge: TPS2SIFBridge);
begin
  inherited Create;
  FBridge := Bridge;
end;

function TPS2SIF0Port.Pull(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := 0;
  var D := PCardinal(Data);
  while (Result < Count) and (FBridge.FIFO0.Count >= 4) do
  begin
    for var K := 0 to 3 do
      D[Result * 4 + K] := FBridge.FIFO0.Pop;
    Inc(Result);
  end;
  if (Result > 0) and Assigned(FBridge.OnIOPRoom) then
    FBridge.OnIOPRoom();
end;

{ TPS2SIF1Port }

constructor TPS2SIF1Port.Create(Bridge: TPS2SIFBridge);
begin
  inherited Create;
  FBridge := Bridge;
end;

function TPS2SIF1Port.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := 0;
  var D := PCardinal(Data);
  while (Result < Count) and (FBridge.FIFO1.Room >= 4) do
  begin
    for var K := 0 to 3 do
      FBridge.FIFO1.Push(D[Result * 4 + K]);
    Inc(Result);
  end;
  if (Result > 0) and Assigned(FBridge.OnIOPData) then
    FBridge.OnIOPData();
end;

procedure TPS2SIF1Port.Tag(Channel: Integer; const Tag: TPS2Reg128);
begin
  FBridge.FIFO1.Push(Tag.UW[2]);
  FBridge.FIFO1.Push(Tag.UW[3]);
  if Assigned(FBridge.OnIOPData) then
    FBridge.OnIOPData();
end;

end.
