unit DC.Interrupts;

// Holly's interrupt status (SB_ISTNRM/EXT/ERR) and the three level masks
// (IML2/4/6) that drive the SH-4 IRL inputs at priorities 2, 4 and 6.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TDCIRLChanged = procedure(User: Pointer; Level: Integer);

  TDCInterruptState = record
    Normal, external, Error: Cardinal;
    Masks: array[0..2, 0..2] of Cardinal; // [IML2/4/6][NRM/EXT/ERR]
  end;

  TDCInterrupts = class
  private
    FChanged: TDCIRLChanged;
    FUser: Pointer;
    FLevel: Integer;
    procedure Update;
  public
    S: TDCInterruptState;
    constructor Create(Changed: TDCIRLChanged; User: Pointer);
    procedure Reset;
    procedure RaiseNormal(Bit: Integer);
    procedure SetExternal(Bit: Integer; Active: Boolean);
    procedure RaiseError(Bit: Integer);
    function NormalStatus: Cardinal;
    procedure AcknowledgeNormal(Value: Cardinal);
    procedure AcknowledgeError(Value: Cardinal);
    procedure SetMask(Level, Kind: Integer; Value: Cardinal);
    procedure SerializeState(Archive: TStateArchive);
    property Level: Integer read FLevel;
  end;

implementation

constructor TDCInterrupts.Create(Changed: TDCIRLChanged; User: Pointer);
begin
  inherited Create;
  FChanged := Changed;
  FUser := User;
  Reset;
end;

procedure TDCInterrupts.Reset;
begin
  S := Default(TDCInterruptState);
  FLevel := -1;
  Update;
end;

function TDCInterrupts.NormalStatus: Cardinal;
begin
  // Bits 30/31 summarize pending external and error causes.
  Result := S.Normal and $3FFFFFFF;
  if S.external <> 0 then
    Result := Result or $40000000;
  if S.Error <> 0 then
    Result := Result or $80000000;
end;

procedure TDCInterrupts.Update;
begin
  var Normal := NormalStatus;
  var NewLevel := 0;
  for var L := 2 downto 0 do
    if ((Normal and S.Masks[L, 0]) or (S.external and S.Masks[L, 1]) or (S.Error and S.Masks[L, 2])) <> 0 then
    begin
      NewLevel := 2 + L * 2;
      Break;
    end;
  if NewLevel <> FLevel then
  begin
    FLevel := NewLevel;
    FChanged(FUser, NewLevel);
  end;
end;

procedure TDCInterrupts.RaiseNormal(Bit: Integer);
begin
  S.Normal := S.Normal or (Cardinal(1) shl Bit);
  Update;
end;

procedure TDCInterrupts.SetExternal(Bit: Integer; Active: Boolean);
begin
  var Old := S.external;
  if Active then
    S.external := S.external or (Cardinal(1) shl Bit)
  else
    S.external := S.external and not (Cardinal(1) shl Bit);
  if Old <> S.external then
    Update;
end;

procedure TDCInterrupts.RaiseError(Bit: Integer);
begin
  S.Error := S.Error or (Cardinal(1) shl Bit);
  Update;
end;

procedure TDCInterrupts.AcknowledgeNormal(Value: Cardinal);
begin
  S.Normal := S.Normal and not (Value and $3FFFFFFF);
  Update;
end;

procedure TDCInterrupts.AcknowledgeError(Value: Cardinal);
begin
  S.Error := S.Error and not Value;
  Update;
end;

procedure TDCInterrupts.SetMask(Level, Kind: Integer; Value: Cardinal);
begin
  S.Masks[Level, Kind] := Value;
  Update;
end;

procedure TDCInterrupts.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading then
  begin
    FLevel := -1;
    Update;
  end;
end;

end.

