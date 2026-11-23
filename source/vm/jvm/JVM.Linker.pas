unit JVM.Linker;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile;

type
  TJVMClassResolver = reference to function(const Name: string): TJVMClass;

  TJVMClassLinker = class
  private
    FResolve: TJVMClassResolver;
    function LookupField(C: TJVMClass; const Name, Descriptor: string; out Owner: TJVMClass; Depth: Integer): TJVMField;
    function LookupMethod(C: TJVMClass; const Name, Descriptor: string; Depth: Integer): TJVMMethod;
    function Overrides(A, B: TJVMMethod; Depth: Integer): Boolean;
  public
    constructor Create(const Resolve: TJVMClassResolver);
    procedure Link(C: TJVMClass);
    function ResolveClass(const Name: string; Caller: TJVMClass = nil): TJVMClass;
    function IsSubclass(C, Parent: TJVMClass): Boolean;
    procedure ClassAccess(Caller, Target: TJVMClass);
    procedure MemberAccess(Caller, Owner: TJVMClass; Flags: Word; const ReceiverClass: string = '');
    function Field(C: TJVMClass; const Name, Descriptor: string; out Owner: TJVMClass): TJVMField;
    function Method(C: TJVMClass; const Name, Descriptor: string): TJVMMethod;
    function MethodReference(C: TJVMClass; const Name, Descriptor: string; InterfaceReference: Boolean): TJVMMethod;
    function VirtualMethod(Actual: TJVMClass; Resolved: TJVMMethod; InterfaceCall: Boolean): TJVMMethod;
    function SpecialMethod(Caller: TJVMClass; Resolved: TJVMMethod): TJVMMethod;
  end;

function JVMPackage(const ClassName: string): string;

procedure JVMLinkFailure(const Kind, Message: string);

implementation

function JVMPackage(const ClassName: string): string;
begin
  Result := Copy(ClassName, 1, LastDelimiter('/', ClassName));
end;

procedure JVMLinkFailure(const Kind, Message: string);
begin
  raise EJVMLinkError.Create('java/lang/' + Kind, Message);
end;

constructor TJVMClassLinker.Create(const Resolve: TJVMClassResolver);
begin
  inherited Create;
  if not Assigned(Resolve) then
    raise EArgumentNilException.Create('Resolve');
  FResolve := Resolve;
end;

function TJVMClassLinker.IsSubclass(C, Parent: TJVMClass): Boolean;
var
  Depth: Integer;
begin
  Depth := 0;
  while C <> nil do
  begin
    if C = Parent then
      Exit(True);
    if C.SuperName = '' then
      Break;
    C := FResolve(C.SuperName);
    Inc(Depth);
    if Depth > 256 then
      JVMLinkFailure('ClassCircularityError', 'Cyclic/deep superclass chain');
  end;
  Result := False;
end;

procedure TJVMClassLinker.ClassAccess(Caller, Target: TJVMClass);
begin
  if (Caller = nil) or ((Target.Access and JVM_ACC_PUBLIC) <> 0) or
    (JVMPackage(Caller.Name) = JVMPackage(Target.Name)) then
    Exit;
  JVMLinkFailure('IllegalAccessError', Caller.Name + ' cannot access class ' + Target.Name);
end;

procedure TJVMClassLinker.MemberAccess(Caller, Owner: TJVMClass; Flags: Word; const ReceiverClass: string);
var
  SamePackage: Boolean;
begin
  if Caller = nil then
    Exit; // Explicit embedding operations are trusted.
  if (Flags and JVM_ACC_PUBLIC) <> 0 then
    Exit;
  if (Flags and JVM_ACC_PRIVATE) <> 0 then
  begin
    if Caller = Owner then
      Exit;
    JVMLinkFailure('IllegalAccessError', Caller.Name + ' cannot access private member of ' + Owner.Name);
  end;
  SamePackage := JVMPackage(Caller.Name) = JVMPackage(Owner.Name);
  if SamePackage then
    Exit;
  if ((Flags and JVM_ACC_PROTECTED) <> 0) and IsSubclass(Caller, Owner) then
  begin
    if ((Flags and JVM_ACC_STATIC) = 0) and (ReceiverClass <> '') and
      (ReceiverClass.StartsWith('[') or not IsSubclass(FResolve(ReceiverClass), Caller)) then
      JVMLinkFailure('IllegalAccessError', 'Invalid cross-package protected receiver');
    Exit;
  end;
  JVMLinkFailure('IllegalAccessError', Caller.Name + ' cannot access member of ' + Owner.Name);
end;

procedure TJVMClassLinker.Link(C: TJVMClass);
var
  Parent, InterfaceClass, Base: TJVMClass;
  Depth: Integer;
  Ancestor: TJVMMethod;
begin
  if C.LinkState = 2 then
    Exit;
  if C.LinkState = 3 then
    raise EJVMLinkError.Create(C.LinkErrorClass, C.LinkError);
  if C.LinkState = 1 then
    JVMLinkFailure('ClassCircularityError', C.Name);
  C.LinkState := 1;
  try
    if C.SuperName <> '' then
    begin
      Parent := FResolve(C.SuperName);
      Link(Parent);
      ClassAccess(C, Parent);
      if (Parent.Access and $0200) <> 0 then
        JVMLinkFailure('IncompatibleClassChangeError', 'Superclass is an interface: ' + Parent.Name);
      if (Parent.Access and JVM_ACC_FINAL) <> 0 then
        JVMLinkFailure('IncompatibleClassChangeError', 'Superclass is final: ' + Parent.Name);
    end
    else
      Parent := nil;
    for var Name in C.Interfaces do
    begin
      InterfaceClass := FResolve(Name);
      Link(InterfaceClass);
      ClassAccess(C, InterfaceClass);
      if (InterfaceClass.Access and $0200) = 0 then
        JVMLinkFailure('IncompatibleClassChangeError', 'Superinterface is a class: ' + Name);
    end;
    for var M in C.Methods do
      if (M.Name <> '<init>') and (M.Name <> '<clinit>') then
      begin
        Base := Parent;
        Depth := 0;
        while Base <> nil do
        begin
          Ancestor := Base.FindMethod(M.Name, M.Descriptor);
          if (Ancestor <> nil) and ((Ancestor.Access and JVM_ACC_FINAL) <> 0) and Overrides(M, Ancestor, 0) then
            JVMLinkFailure('IncompatibleClassChangeError', C.Name + ' overrides final method ' + Ancestor.Owner.Name + '.' + M.Name);
          if Base.SuperName = '' then
            Break;
          Base := FResolve(Base.SuperName);
          Inc(Depth);
          if Depth > 256 then
            JVMLinkFailure('ClassCircularityError', C.Name);
        end;
      end;
    C.LinkState := 2;
  except
    on E: EJVMLinkError do
    begin
      C.LinkState := 3;
      C.LinkErrorClass := E.JavaClass;
      C.LinkError := E.Message;
      raise;
    end;
    on E: Exception do
    begin
      C.LinkState := 0;
      raise;
    end;
  end;
end;

function TJVMClassLinker.ResolveClass(const Name: string; Caller: TJVMClass): TJVMClass;
var
  Component: string;
  P: Integer;
begin
  JVMClassName(Name);
  Component := Name;
  if Name.StartsWith('[') then
  begin
    P := 1;
    while (P <= Length(Name)) and (Name[P] = '[') do
      Inc(P);
    Component := Copy(Name, P, MaxInt);
    if Component.StartsWith('L') then
    begin
      Component := Copy(Component, 2, Length(Component) - 2);
      var ElementClass := FResolve(Component);
      Link(ElementClass);
      ClassAccess(Caller, ElementClass);
    end;
    Component := 'java/lang/Object';
  end;
  Result := FResolve(Component);
  Link(Result);
  ClassAccess(Caller, Result);
end;

function TJVMClassLinker.LookupField(C: TJVMClass; const Name, Descriptor: string; out Owner: TJVMClass; Depth: Integer): TJVMField;
begin
  if Depth > 256 then
    JVMLinkFailure('ClassCircularityError', 'Deep field hierarchy');
  for Result in C.Fields do
    if (Result.Name = Name) and (Result.Descriptor = Descriptor) then
    begin
      Owner := C;
      Exit;
    end;
  for var I in C.Interfaces do
  begin
    Result := LookupField(FResolve(I), Name, Descriptor, Owner, Depth + 1);
    if Result <> nil then
      Exit;
  end;
  if C.SuperName <> '' then
    Exit(LookupField(FResolve(C.SuperName), Name, Descriptor, Owner, Depth + 1));
  Result := nil;
end;

function TJVMClassLinker.Field(C: TJVMClass; const Name, Descriptor: string; out Owner: TJVMClass): TJVMField;
begin
  Link(C);
  Result := LookupField(C, Name, Descriptor, Owner, 0);
  if Result = nil then
    JVMLinkFailure('NoSuchFieldError', C.Name + '.' + Name + ':' + Descriptor);
end;

function TJVMClassLinker.LookupMethod(C: TJVMClass; const Name, Descriptor: string; Depth: Integer): TJVMMethod;
begin
  if Depth > 256 then
    JVMLinkFailure('ClassCircularityError', 'Deep method hierarchy');
  Result := C.FindMethod(Name, Descriptor);
  if Result <> nil then
    Exit;
  if (Name = '<init>') or (Name = '<clinit>') then
    Exit(nil);
  if (C.Access and $0200) <> 0 then
  begin
    Result := FResolve('java/lang/Object').FindMethod(Name, Descriptor);
    if (Result <> nil) and ((Result.Access and (JVM_ACC_PUBLIC or JVM_ACC_STATIC)) = JVM_ACC_PUBLIC) then
      Exit;
  end
  else if C.SuperName <> '' then
  begin
    Result := LookupMethod(FResolve(C.SuperName), Name, Descriptor, Depth + 1);
    if Result <> nil then
      Exit;
  end;
  for var I in C.Interfaces do
  begin
    Result := LookupMethod(FResolve(I), Name, Descriptor, Depth + 1);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function TJVMClassLinker.Method(C: TJVMClass; const Name, Descriptor: string): TJVMMethod;
begin
  Link(C);
  Result := LookupMethod(C, Name, Descriptor, 0);
  if Result = nil then
    JVMLinkFailure('NoSuchMethodError', C.Name + '.' + Name + Descriptor);
end;

function TJVMClassLinker.MethodReference(C: TJVMClass; const Name, Descriptor: string; InterfaceReference: Boolean): TJVMMethod;
begin
  Link(C);
  if ((C.Access and $0200) <> 0) <> InterfaceReference then
    JVMLinkFailure('IncompatibleClassChangeError', 'Method reference class/interface mismatch: ' + C.Name);
  Result := Method(C, Name, Descriptor);
end;

function TJVMClassLinker.Overrides(A, B: TJVMMethod; Depth: Integer): Boolean;
var
  Base: TJVMClass;
  Intermediate: TJVMMethod;
  Level: Integer;
begin
  if A = B then
    Exit(True);
  if Depth > 256 then
    JVMLinkFailure('ClassCircularityError', 'Deep overriding chain');
  if ((A.Access or B.Access) and (JVM_ACC_PRIVATE or JVM_ACC_STATIC)) <> 0 then
    Exit(False);
  if not IsSubclass(A.Owner, B.Owner) then
    Exit(False);
  if ((B.Access and (JVM_ACC_PUBLIC or JVM_ACC_PROTECTED)) <> 0) or
    (JVMPackage(A.Owner.Name) = JVMPackage(B.Owner.Name)) then
    Exit(True);
  Base := A.Owner;
  Level := 0;
  while (Base.SuperName <> '') and (Base <> B.Owner) do
  begin
    Base := FResolve(Base.SuperName);
    Intermediate := Base.FindMethod(A.Name, A.Descriptor);
    if (Intermediate <> nil) and (Intermediate <> B) and Overrides(Intermediate, B, Depth + 1) and
      Overrides(A, Intermediate, Depth + 1) then
      Exit(True);
    Inc(Level);
    if Level > 256 then
      JVMLinkFailure('ClassCircularityError', 'Cyclic overriding chain');
  end;
  Result := False;
end;

function TJVMClassLinker.VirtualMethod(Actual: TJVMClass; Resolved: TJVMMethod; InterfaceCall: Boolean): TJVMMethod;
var
  C: TJVMClass;
  Candidate: TJVMMethod;
  Depth: Integer;
begin
  if not InterfaceCall and ((Resolved.Access and JVM_ACC_PRIVATE) <> 0) then
    Exit(Resolved);
  C := Actual;
  Depth := 0;
  while C <> nil do
  begin
    Candidate := C.FindMethod(Resolved.Name, Resolved.Descriptor);
    if (Candidate <> nil) and ((Candidate.Access and JVM_ACC_STATIC) = 0) and
      (InterfaceCall or Overrides(Candidate, Resolved, 0)) then
    begin
      if InterfaceCall and ((Candidate.Access and JVM_ACC_PUBLIC) = 0) then
        JVMLinkFailure('IllegalAccessError', 'Interface implementation is not public');
      Exit(Candidate);
    end;
    if C.SuperName = '' then
      Break;
    C := FResolve(C.SuperName);
    Inc(Depth);
    if Depth > 256 then
      JVMLinkFailure('ClassCircularityError', 'Deep method selection');
  end;
  JVMLinkFailure('AbstractMethodError', Actual.Name + '.' + Resolved.Name);
  Result := nil;
end;

function TJVMClassLinker.SpecialMethod(Caller: TJVMClass; Resolved: TJVMMethod): TJVMMethod;
begin
  Result := Resolved;
  if ((Caller.Access and $0020) <> 0) and (Caller <> Resolved.Owner) and
    (Resolved.Name <> '<init>') and IsSubclass(Caller, Resolved.Owner) then
    Result := Method(FResolve(Caller.SuperName), Resolved.Name, Resolved.Descriptor);
end;

end.

