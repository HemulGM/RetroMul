unit PS2.GS.Raster;

// GS drawing: the general registers, primitive assembly and the pixel
// pipeline (texture, fog, tests, blending), and host/local transfers.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types, PS2.GS.Memory;

type
  TPS2GSRaster = class
  private
    FMemory: TPS2GSMemory;
    FOnSignal: TProc;
    FSignal, FFinish: Boolean;
  public
    Regs: array[0..$7F] of UInt64;
    SigLblId: UInt64;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure WriteRegister(Index: Integer; Value: UInt64);
    procedure WriteImage(const Data: TPS2Reg128);
    function ReadImage(out Data: TPS2Reg128): Boolean;
    procedure ClearSignal;
    procedure ClearFinish;
    procedure SerializeState(State: TStateArchive);
    property Memory: TPS2GSMemory read FMemory;
    property SignalPending: Boolean read FSignal;
    property FinishPending: Boolean read FFinish;
    property OnSignal: TProc read FOnSignal write FOnSignal;
  end;

implementation

constructor TPS2GSRaster.Create;
begin
  inherited Create;
  FMemory := TPS2GSMemory.Create;
  Reset;
end;

destructor TPS2GSRaster.Destroy;
begin
  FMemory.Free;
  inherited;
end;

procedure TPS2GSRaster.Reset;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  FSignal := False;
  FFinish := False;
  SigLblId := 0;
  FMemory.Clear;
end;

procedure TPS2GSRaster.WriteRegister(Index: Integer; Value: UInt64);
begin
  Regs[Index and $7F] := Value;
  case Index of
    $60:
      begin
        SigLblId := (SigLblId and not (Value shr 32)) or (Value and (Value shr 32) and $FFFFFFFF);
        FSignal := True;
      end;
    $61: FFinish := True;
    $62: SigLblId := (SigLblId and not ((Value shr 32) shl 32)) or ((Value and (Value shr 32)) shl 32);
  end;
end;

procedure TPS2GSRaster.WriteImage(const Data: TPS2Reg128);
begin
end;

function TPS2GSRaster.ReadImage(out Data: TPS2Reg128): Boolean;
begin
  Data := Default(TPS2Reg128);
  Result := False;
end;

procedure TPS2GSRaster.ClearSignal;
begin
  FSignal := False;
end;

procedure TPS2GSRaster.ClearFinish;
begin
  FFinish := False;
end;

procedure TPS2GSRaster.SerializeState(State: TStateArchive);
begin
  State.Field(Regs, SizeOf(Regs));
  State.Field(SigLblId, SizeOf(SigLblId));
  State.Field(FSignal, SizeOf(FSignal));
  State.Field(FFinish, SizeOf(FFinish));
  State.Field(FMemory.Data^, PS2GSMemorySize);
end;

end.
