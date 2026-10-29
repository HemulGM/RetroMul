unit A2600.State;

interface

uses
  Core.Snapshots, A2600.Cartridge, A2600.RIOT, A2600.TIA;

procedure TransferA2600MachineState(State: TStateArchive; Cartridge: TA2600Cartridge; RIOT: TA2600RIOT; TIA: TA2600TIA; var Bus: Byte; var AudioPhase: Double);

implementation

type
  // Frozen snapshot v1 layout, including the original field order/alignment.
  // It is a persistence adapter, never the live hardware state.
  TA2600LegacyState = record
    RAM, CartRAM: array[0..127] of Byte;
    FA_RAM: array[0..255] of Byte;
    R: array[0..63] of Byte;
    Collision: array[0..7] of Byte;
    Position: array[0..4] of Integer;
    OldPlayer: array[0..1] of Byte;
    OldBall: Byte;
    Bank: Integer;
    Segments: array[0..2] of Integer;
    H, Line, TimerDivider, TimerPhase: Integer;
    Timer, TimerFlag, PortA, DDRA, PortB, DDRB, Bus: Byte;
    TimerRunning, TimerUnderflow, Waiting, FrameReady: Boolean;
    FrameNumber: UInt64;
    AudioPhase: Double;
  end;

procedure TransferA2600MachineState(State: TStateArchive; Cartridge: TA2600Cartridge; RIOT: TA2600RIOT; TIA: TA2600TIA; var Bus: Byte; var AudioPhase: Double);
var
  Legacy: TA2600LegacyState;
begin
  FillChar(Legacy, SizeOf(Legacy), 0);
  var Cart := Cartridge.SnapshotState;
  var RIOTState := RIOT.SnapshotState;
  var TIAState := TIA.SnapshotState;
  Move(RIOTState.RAM, Legacy.RAM, SizeOf(Legacy.RAM));
  Move(Cart.RAM, Legacy.CartRAM, SizeOf(Legacy.CartRAM));
  Move(Cart.FARAM, Legacy.FA_RAM, SizeOf(Legacy.FA_RAM));
  Move(TIAState.Registers, Legacy.R, SizeOf(Legacy.R));
  Move(TIAState.Collision, Legacy.Collision, SizeOf(Legacy.Collision));
  Move(TIAState.ObjectPositions, Legacy.Position, SizeOf(Legacy.Position));
  Move(TIAState.DelayedPlayers, Legacy.OldPlayer, SizeOf(Legacy.OldPlayer));
  Legacy.OldBall := TIAState.DelayedBall;
  Legacy.Bank := Cart.Bank;
  Move(Cart.Segments, Legacy.Segments, SizeOf(Legacy.Segments));
  Legacy.H := TIAState.HorizontalClock;
  Legacy.Line := TIAState.Line;
  Legacy.TimerDivider := RIOTState.TimerDivider;
  Legacy.TimerPhase := RIOTState.TimerPhase;
  Legacy.Timer := RIOTState.Timer;
  Legacy.TimerFlag := RIOTState.TimerFlag;
  Legacy.PortA := RIOTState.PortA;
  Legacy.DDRA := RIOTState.DDRA;
  Legacy.PortB := RIOTState.PortB;
  Legacy.DDRB := RIOTState.DDRB;
  Legacy.Bus := Bus;
  Legacy.TimerRunning := RIOTState.TimerRunning;
  Legacy.TimerUnderflow := RIOTState.TimerUnderflow;
  Legacy.Waiting := TIAState.Waiting;
  Legacy.FrameReady := TIAState.FrameReady;
  Legacy.FrameNumber := TIAState.FrameNumber;
  Legacy.AudioPhase := AudioPhase;
  State.Field(Legacy, SizeOf(Legacy));
  State.Field(RIOTState.TimerWrapped, SizeOf(Boolean));
  if State.Loading then
  begin
    Move(Legacy.RAM, RIOTState.RAM, SizeOf(Legacy.RAM));
    Move(Legacy.CartRAM, Cart.RAM, SizeOf(Legacy.CartRAM));
    Move(Legacy.FA_RAM, Cart.FARAM, SizeOf(Legacy.FA_RAM));
    Move(Legacy.R, TIAState.Registers, SizeOf(Legacy.R));
    Move(Legacy.Collision, TIAState.Collision, SizeOf(Legacy.Collision));
    Move(Legacy.Position, TIAState.ObjectPositions, SizeOf(Legacy.Position));
    Move(Legacy.OldPlayer, TIAState.DelayedPlayers, SizeOf(Legacy.OldPlayer));
    TIAState.DelayedBall := Legacy.OldBall;
    Cart.Bank := Legacy.Bank;
    Move(Legacy.Segments, Cart.Segments, SizeOf(Legacy.Segments));
    TIAState.HorizontalClock := Legacy.H;
    TIAState.Line := Legacy.Line;
    RIOTState.TimerDivider := Legacy.TimerDivider;
    RIOTState.TimerPhase := Legacy.TimerPhase;
    RIOTState.Timer := Legacy.Timer;
    RIOTState.TimerFlag := Legacy.TimerFlag;
    RIOTState.PortA := Legacy.PortA;
    RIOTState.DDRA := Legacy.DDRA;
    RIOTState.PortB := Legacy.PortB;
    RIOTState.DDRB := Legacy.DDRB;
    Bus := Legacy.Bus;
    RIOTState.TimerRunning := Legacy.TimerRunning;
    RIOTState.TimerUnderflow := Legacy.TimerUnderflow;
    TIAState.Waiting := Legacy.Waiting;
    TIAState.FrameReady := Legacy.FrameReady;
    TIAState.FrameNumber := Legacy.FrameNumber;
    AudioPhase := Legacy.AudioPhase;
    Cartridge.SnapshotState := Cart;
    RIOT.SnapshotState := RIOTState;
    TIA.SnapshotState := TIAState;
    Cartridge.ValidateState;
    TIA.ValidateState;
  end;
end;

end.

