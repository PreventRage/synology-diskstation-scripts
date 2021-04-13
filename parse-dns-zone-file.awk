#!/bin/gawk

function Init() {
  g_Error = 0
}

function Log(msg) {
  printf("%s:%d: %s\n", FILENAME, FNR, msg) > "/dev/stdout"
}

function Error(msg) {
  printf("%s:%d: Error: %s\n", FILENAME, FNR, msg) > "/dev/stderr"
  g_Error = 1
  exit 1
}

function Assert(condition, msg) {
  if (!condition) {
    Error("Assertion Failed: " msg)
  }
}

function BeginRecord() {
  delete g_Lines # now an empty array
  g_CountOfLines = 0

  g_Directive = ""

  delete g_Fields # now an empty array
  g_CurrentField = ""

  g_RecordIsComplete = 0
  g_RecordIsIncomplete = 0
}

function AddField(field) {
  printf("F[%s] ", field)
}

function OpenField() {
  printf("( ")
}

function CloseField() {
  printf("( ")
}

function AfterPrintArray() {
}

function PrintArray(a,     i) {
  for (i in a) {
    printf("a[%s]=[%s]\n", i, a[i])
  }
  AfterPrintArray()
}

function ProcessLine(line,     iLine, cch, ich, ch, j, M) {
  iLine = g_CountOfLines + 1
  g_Lines[iLine] = line
  cch = length(line)
  token = ""
  for (ich = 1; ich <= cch; ich++) {
    ch = substr(line, ich, 1)
    if (ch == "\\") {
      
    }
    
    

  }

  x = line


  # Pull comment off end of line
  if (match(x, /^(.*)(;.*)$/, M)) {
    g_Lines[i, "comment"] = M[2] # includes semi-colon so that "empty comment" is still a comment
    x = Matches[1]
  }

  if (i == 1) {
    if (match(x, /^\s*\$(\w+)(.*)$/, M)) {
      g_Directive = M[1]
      x = M[2]
    }
  }

  while (1) {
    # Check for quoted string field (unmatched matches to EOL)
    if (match(x, /^\s*"([^"]*)"?)(.*)$/, M)) { #"
      AddField(M[1])
      x = M[2]
    }
    # Check for space delimted field
    else if (match(x, /^\s*(\S+)(.*)$/, M)) {
      # Which might be a ( or a )
      # Right now we require ( and ) to be space delimited.
      # Could change that 
      if (M[1] == "(") {
        OpenField()
      } else if (M[1] == ")") {
        CloseField()
      } else {
        AddField(M[1])
      }
      x = M[2]
    } else {
      break
    }
  }

  g_Lines[i, "data"] = x
  g_CountOfLines = i
  g_RecordIsComplete = 1
}


function ProcessRun(type, run) {
  # type is one of
    # 0 = EOL
    # 1 = normal run of text
    # 2 = spaces
    # 3 = quotation mark
    # 4 = semi-colon
  if (runs_inQuote) {
    # quotes end at the next quotation mark.
    # Even EOLs goes into the quote.
    if (type == 3) { 
      runs_FinishToken()
    } else {
      runs_token += run
    }
  }
  else if (runs_inComment) {
    # comments end at EOL.
    if (type == 0) {
      runs_FinishToken()
      ProcessToken(0, run)
    }
    else {
      runs_token += run
    }
  }
  else {
    if (type == 0) { # EOL
      runs_FinishToken()
      ProcessToken(0, run)
    }
    else if (type == 1) { # normal text
      runs_token += run
    }
    else if (type == 2) { # spaces
      runs_FinishToken()
    }
    else if (type == 3) { # quotation mark
      runs_FinishToken()
      runs_inQuote = 1
    }
    else if (type == 4) { # semi-colon
      runs_FinishToken()
      runs_inComment = 1
    }
  }
}

function runs_Init() {
  runs_ClearToken()
}

function runs_ClearToken() {
  runs_token = ""
  runs_inQuote = 0
  runs_inComment = 0
}

function runs_FinishToken() {
  if (runs_inQuote) {
    ProcessToken(1, runs_token)
  }
  else if (runs_inComment) {
    ProcessToken(4, runs_token)
  }
  else if (runs_token == "(") {
    ProcessToken(2, runs_token)
  }
  else if (runs_token == ")" {
    ProcessToken(3, runs_token)
  }
  else if (runs_token != "") {
    ProcessToken(1, runs_token)
  }  
  runs_ClearToken()
}

function ProcessToken(type, token) {
  # type is one of
    # 0 EOL
    # 1 normal token
    # 2 open paren
    # 3 close paren
    # 4 comment
  # token is a string
  switch (type) {
    case 0: # EOL
      # If we're within parens we ignore the EOL,
      # otherwise we pass it along as an EOL field
      if (tokens_InParen <= 0) {
        ProcessField(0) 
      }
      break
    case 1: # normal
      ProcessField(1, token)
      break
    case 2: # open paren
      tokens_InParen += 1
      break
    case 3: # close paren
      tokens_InParen -= 1
      break
    case 4: # comment
      # what should we do with comments?
      break
    default:
      Error(sprintf("Unknown token type [%s](%s) ", type, token))
  }
}

function tokens_Init() {
  tokens_InParen = 0
}

function ProcessField(type, field) {
  # type is one of
    # 0 EOR
    # 1 normal field
  # field is a string
  # if normal append field to array of fields
  # else finish up and call ProcessRecord
}

function ProcessRecord(     i) {
  for (i = 1; i <= g_CountOfLines; i++) {
    printf "D[%s] N[%s] Data[%s]\n",
      g_Lines[i, "directive"],
      g_Lines[i, "name"],
      g_Lines[i, "data"]
  }
}

# {
#     if (p1++ > 3)
#         return

#     a[p1] = p1

#     some_func(p1)

#     printf("At level %d, index %d %s found in a\n",
#          p1, (p1 - 1), (p1 - 1) in a ? "is" : "is not")
#     printf("At level %d, index %d %s found in a\n",
#          p1, p1, p1 in a ? "is" : "is not")
#     print ""
# }
BEGIN {
  #FS="\t" # Set field separator
  Init()
  BeginRecord()
}

{
  ProcessLine($0)
  if (g_RecordIsComplete) {
    ProcessRecord()
    BeginRecord()
  }
  next

  # Line=$0
  # Comment=""

  # if (match(Line, /^(.*);(.*)$/, Matches)) {
  #   Line=Matches[1]
  #   Comment=Matches[2]
  # } 

  # if (InMultiLineParentheses) {
  #   print "[Continued]" $0
  #   if ($0 ~ /\)$/) { # line ends with )
  #     InMultiLineParentheses=0
  #   }
  #   next
  # }

  # if ($1 ~ /^\$/) {
  #   print "[Directive]" $0
  #   next
  # }
  # if (!InMultiLineParentheses) {
  #   if ($0 ~ /^.*\($/) { # line ends with (
  #   InMultiLineParentheses=1
  #   print "ML!>" $0
  #   next
  # }

  # print "[" $1 "][" $2 "][" $3 "][" $4 "][" $5 "][" $6 "]"
  # next
  # if ($5 != ";dynamic") {
  #   PrintThis=1
  # } else {
  #   PrintThis=0
  # }
}

# (PrintThis == 1) {print $0 }

END {
  Assert(!g_RecordIsComplete)
  if (g_RecordIsIncomplete) {
    Error("File ended with incomplete record");
  }
}

