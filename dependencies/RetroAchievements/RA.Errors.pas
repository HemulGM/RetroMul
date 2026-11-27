unit RA.Errors;

interface

const
  RAErrorOK = 0;
  RAErrorInvalidFunctionOperand = -1;
  RAErrorInvalidMemoryOperand = -2;
  RAErrorInvalidConstantOperand = -3;
  RAErrorInvalidFloatOperand = -4;
  RAErrorInvalidConditionType = -5;
  RAErrorInvalidOperator = -6;
  RAErrorInvalidRequiredHits = -7;
  RAErrorDuplicatedStart = -8;
  RAErrorDuplicatedCancel = -9;
  RAErrorDuplicatedSubmit = -10;
  RAErrorDuplicatedValue = -11;
  RAErrorDuplicatedProgress = -12;
  RAErrorMissingStart = -13;
  RAErrorMissingCancel = -14;
  RAErrorMissingSubmit = -15;
  RAErrorMissingValue = -16;
  RAErrorInvalidLeaderboardField = -17;
  RAErrorMissingDisplayString = -18;
  RAErrorOutOfMemory = -19;
  RAErrorInvalidValueFlag = -20;
  RAErrorMissingValueMeasured = -21;
  RAErrorMultipleMeasured = -22;
  RAErrorInvalidMeasuredTarget = -23;
  RAErrorInvalidComparison = -24;
  RAErrorInvalidState = -25;
  RAErrorInvalidJSON = -26;
  RAErrorAPIFailure = -27;
  RAErrorLoginRequired = -28;
  RAErrorNoGameLoaded = -29;
  RAErrorHardcoreDisabled = -30;
  RAErrorAborted = -31;
  RAErrorNoResponse = -32;
  RAErrorAccessDenied = -33;
  RAErrorInvalidCredentials = -34;
  RAErrorExpiredToken = -35;
  RAErrorInsufficientBuffer = -36;
  RAErrorInvalidVariableName = -37;
  RAErrorUnknownVariableName = -38;
  RAErrorNotFound = -39;
  RAErrorInvalidValue = -40;

// Numeric codes and fallback messages from rcheevos rc_error.h and rc_error_str.
function RAErrorMessage(Code: Integer): string;

implementation

function RAErrorMessage(Code: Integer): string;
begin
  case Code of
    RAErrorOK:
      Result := 'OK';
    RAErrorInvalidFunctionOperand:
      Result := 'Invalid function operand';
    RAErrorInvalidMemoryOperand:
      Result := 'Invalid memory operand';
    RAErrorInvalidConstantOperand:
      Result := 'Invalid constant operand';
    RAErrorInvalidFloatOperand:
      Result := 'Invalid floating-point operand';
    RAErrorInvalidConditionType:
      Result := 'Invalid condition type';
    RAErrorInvalidOperator:
      Result := 'Invalid operator';
    RAErrorInvalidRequiredHits:
      Result := 'Invalid required hits';
    RAErrorDuplicatedStart:
      Result := 'Duplicated start condition';
    RAErrorDuplicatedCancel:
      Result := 'Duplicated cancel condition';
    RAErrorDuplicatedSubmit:
      Result := 'Duplicated submit condition';
    RAErrorDuplicatedValue:
      Result := 'Duplicated value expression';
    RAErrorDuplicatedProgress:
      Result := 'Duplicated progress expression';
    RAErrorMissingStart:
      Result := 'Missing start condition';
    RAErrorMissingCancel:
      Result := 'Missing cancel condition';
    RAErrorMissingSubmit:
      Result := 'Missing submit condition';
    RAErrorMissingValue:
      Result := 'Missing value expression';
    RAErrorInvalidLeaderboardField:
      Result := 'Invalid field in leaderboard';
    RAErrorMissingDisplayString:
      Result := 'Missing display string';
    RAErrorOutOfMemory:
      Result := 'Out of memory';
    RAErrorInvalidValueFlag:
      Result := 'Invalid flag in value expression';
    RAErrorMissingValueMeasured:
      Result := 'Missing measured flag in value expression';
    RAErrorMultipleMeasured:
      Result := 'Multiple measured targets';
    RAErrorInvalidMeasuredTarget:
      Result := 'Invalid measured target';
    RAErrorInvalidComparison:
      Result := 'Invalid comparison';
    RAErrorInvalidState:
      Result := 'Invalid state';
    RAErrorInvalidJSON:
      Result := 'Invalid JSON';
    RAErrorAPIFailure:
      Result := 'API call failed';
    RAErrorLoginRequired:
      Result := 'Login required';
    RAErrorNoGameLoaded:
      Result := 'No game loaded';
    RAErrorHardcoreDisabled:
      Result := 'Hardcore disabled';
    RAErrorAborted:
      Result := 'Aborted';
    RAErrorNoResponse:
      Result := 'No response';
    RAErrorAccessDenied:
      Result := 'Access denied';
    RAErrorInvalidCredentials:
      Result := 'Invalid credentials';
    RAErrorExpiredToken:
      Result := 'Expired token';
    RAErrorInsufficientBuffer:
      Result := 'Buffer not large enough';
    RAErrorInvalidVariableName:
      Result := 'Invalid variable name';
    RAErrorUnknownVariableName:
      Result := 'Unknown variable name';
    RAErrorNotFound:
      Result := 'Not found';
    RAErrorInvalidValue:
      Result := 'Invalid value expression';
  else
    Result := 'Unknown error';
  end;
end;

end.

