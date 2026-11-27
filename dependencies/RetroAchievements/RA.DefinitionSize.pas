unit RA.DefinitionSize;

interface

// Returns the C-compatible caller-buffer size, or a negative RAError* parse result.
function RATriggerDefinitionSize(const Expression: string): Integer;

function RAValueDefinitionSize(const Expression: string): Integer;

function RALeaderboardDefinitionSize(const Expression: string): Integer;

function RARichPresenceDefinitionSize(const Script: string): Integer; overload;

function RARichPresenceDefinitionSize(const Script: string; out LinesRead: Integer): Integer; overload;

implementation

uses
  System.SysUtils, RA.Conditions, RA.DefinitionLayout, RA.Errors,
  RA.Leaderboards, RA.MemoryValues, RA.RichPresence, RA.Trigger, RA.Value;

function DefinitionPrefix(const Expression: string): string;
var
  Terminator: Integer;
begin
  Terminator := Pos(#0, Expression);
  if Terminator = 0 then
    Result := Expression
  else
    Result := Copy(Expression, 1, Terminator - 1);
end;

function RATriggerDefinitionSize(const Expression: string): Integer;
var
  Trigger: TRATrigger;
  Memrefs: TRARuntimeMemrefs;
  Layout: TRADefinitionLayout;
  NextPosition: Integer;
begin
  Trigger := nil;
  Memrefs := nil;
  try
    try
      Trigger := TRATrigger.Create(TRATriggerDefinition.ParsePrefix(DefinitionPrefix(Expression), NextPosition));
      Memrefs := TRARuntimeMemrefs.Create;
      Trigger.CollectRCMemrefs(Memrefs, True);
      Layout := TRADefinitionLayout.Create(TRADefinitionKind.Trigger);
      Trigger.MeasureDefinitionLayout(Layout);
      Result := Layout.Finish(Memrefs);
    finally
      Memrefs.Free;
      Trigger.Free;
    end;
  except
    on Error: ERAConditionError do
      Result := Error.Code;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

function RAValueDefinitionSize(const Expression: string): Integer;
var
  Value: TRAValue;
  Memrefs: TRARuntimeMemrefs;
  Layout: TRADefinitionLayout;
begin
  Value := nil;
  Memrefs := nil;
  try
    try
      Value := TRAValue.Create(DefinitionPrefix(Expression), True, True);
      Memrefs := TRARuntimeMemrefs.Create;
      Value.CollectRCMemrefs(Memrefs, True);
      Layout := TRADefinitionLayout.Create(TRADefinitionKind.Value);
      Value.MeasureDefinitionLayout(Layout);
      Result := Layout.Finish(Memrefs);
    finally
      Memrefs.Free;
      Value.Free;
    end;
  except
    on Error: ERAConditionError do
      Result := Error.Code;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

function RALeaderboardDefinitionSize(const Expression: string): Integer;
var
  Board: TRALeaderboard;
  Memrefs: TRARuntimeMemrefs;
  Layout: TRADefinitionLayout;
begin
  Board := nil;
  Memrefs := nil;
  try
    try
      Board := TRALeaderboard.Create(DefinitionPrefix(Expression));
      Memrefs := TRARuntimeMemrefs.Create;
      Board.CollectRCMemrefs(Memrefs, True);
      Layout := TRADefinitionLayout.Create(TRADefinitionKind.Leaderboard);
      Board.MeasureDefinitionLayout(Layout);
      Result := Layout.Finish(Memrefs);
    finally
      Memrefs.Free;
      Board.Free;
    end;
  except
    on Error: ERAConditionError do
      Result := Error.Code;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

function RARichPresenceDefinitionSize(const Script: string; out LinesRead: Integer): Integer;
var
  Presence: TRARichPresence;
  Memrefs: TRARuntimeMemrefs;
  Layout: TRADefinitionLayout;
begin
  LinesRead := 1;
  Presence := nil;
  Memrefs := nil;
  try
    try
      Presence := TRARichPresence.Create(Script);
      LinesRead := Presence.DefinitionLinesRead;
      Memrefs := TRARuntimeMemrefs.Create;
      Presence.CollectRCMemrefs(Memrefs, True);
      Layout := Presence.GetDefinitionLayout;
      Result := Layout.Finish(Memrefs);
    finally
      Memrefs.Free;
      Presence.Free;
    end;
  except
    on Error: ERARichPresenceError do
    begin
      LinesRead := Error.Line;
      Result := Error.Code;
    end;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

function RARichPresenceDefinitionSize(const Script: string): Integer;
var
  LinesRead: Integer;
begin
  Result := RARichPresenceDefinitionSize(Script, LinesRead);
end;

end.

