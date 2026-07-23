# 실행 중 관찰 가능한 작업자 진행 이벤트를 안전하게 기록하고 표시한다.

Set-StrictMode -Version Latest

function Get-ProgressConfig {
    $defaults = [ordered]@{
        pollIntervalMilliseconds = 1000
        heartbeatSeconds = 15
        maxSummaryCharacters = 500
        maxJournalBytes = 1048576
        followCheckpointSeconds = 600
    }
    try {
        $cfg = Get-Config
        if ($cfg.PSObject.Properties.Name -contains 'progress') {
            foreach ($name in @($defaults.Keys)) {
                if ($cfg.progress.PSObject.Properties.Name -contains $name) { $defaults[$name] = [int]$cfg.progress.$name }
            }
        }
    } catch {}
    return [pscustomobject]$defaults
}

function Get-ExecutionProgressPath {
    param([Parameter(Mandatory)]$Receipt)
    if ($Receipt.PSObject.Properties.Name -contains 'progressPath' -and -not [string]::IsNullOrWhiteSpace([string]$Receipt.progressPath)) {
        return [string]$Receipt.progressPath
    }
    return (Join-Path ([string]$Receipt.artifactPath) 'progress.jsonl')
}

function Initialize-ExecutionProgress {
    param([Parameter(Mandatory)]$Receipt)
    $path = Get-ExecutionProgressPath -Receipt $Receipt
    Assert-PathWithinRoot -Path $path -Root ([string]$Receipt.artifactPath) | Out-Null
    if (-not (Test-Path -LiteralPath $path)) {
        [System.IO.File]::WriteAllText($path, '', (New-Object System.Text.UTF8Encoding($false)))
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($item in @(
        @('progressSchemaVersion',1),@('progressPath',$path),@('progressStartedAt',$now),
        @('progressLastEventAt',$null),@('progressEventCount',0))) {
        Add-Member -InputObject $Receipt -NotePropertyName $item[0] -NotePropertyValue $item[1] -Force
    }
    return $Receipt
}

function ConvertTo-ProgressSummary {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = Protect-SecretText -Text $Text
    $safe = [regex]::Replace($safe, '[\r\n\t]+', ' ')
    $safe = [regex]::Replace($safe, '\s{2,}', ' ').Trim()
    $max = [Math]::Max(1, [int](Get-ProgressConfig).maxSummaryCharacters)
    if ($safe.Length -gt $max) { $safe = $safe.Substring(0,$max) }
    return $safe
}

function Write-ExecutionProgressEvent {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][ValidateSet('execution_created','worker_process_started','worker_output_activity','command_started','command_completed','file_changed','git_state_changed','test_started','test_completed','commit_detected','push_detected','heartbeat','worker_exited','artifact_sanitized','postflight_started','postflight_completed','operation_terminal','progress_suppressed')][string]$Event,
        [string]$Phase = 'implementation',
        [ValidateSet('info','warning','error')][string]$Level = 'info',
        [AllowEmptyString()][string]$Summary = ''
    )
    $path = Get-ExecutionProgressPath -Receipt $Receipt
    $artifact = [string]$Receipt.artifactPath
    Assert-PathWithinRoot -Path $path -Root $artifact | Out-Null
    $lockPath = $path + '.lock'
    Assert-PathWithinRoot -Path $lockPath -Root $artifact | Out-Null
    $cfg = Get-ProgressConfig
    $critical = $Event -in @('heartbeat','worker_exited','artifact_sanitized','postflight_started','postflight_completed','operation_terminal','progress_suppressed')
    $lock = $null
    for ($attempt=0; $attempt -lt 40 -and $null -eq $lock; $attempt++) {
        try { $lock = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds ([Math]::Min(250,25 * ($attempt + 1))) }
    }
    if ($null -eq $lock) {
        $message = ConvertTo-ProgressSummary -Text "progress lock unavailable for $Event"
        try { Add-Content -LiteralPath ([string]$Receipt.logPath) -Value "`nprogress_error=$message" -Encoding UTF8 } catch {}
        return $null
    }
    try {
        if (-not (Test-Path -LiteralPath $path)) { [System.IO.File]::WriteAllText($path,'',(New-Object System.Text.UTF8Encoding($false))) }
        $existing = Read-SharedTextFile -Path $path
        $lastSeq = 0; $suppressedAlready = $false
        foreach ($line in @($existing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            try {
                $parsed = $line | ConvertFrom-Json -ErrorAction Stop
                if ([int]$parsed.seq -gt $lastSeq) { $lastSeq = [int]$parsed.seq }
                if ([string]$parsed.event -eq 'progress_suppressed') { $suppressedAlready = $true }
            } catch {}
        }
        $size = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).Length } else { 0 }
        if ($size -ge [int64]$cfg.maxJournalBytes -and -not $critical) {
            if ($suppressedAlready) { return $null }
            $Event = 'progress_suppressed'; $Level = 'warning'; $Summary = 'progress journal size limit reached; detail events suppressed'; $critical = $true
        }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $entry = [ordered]@{
            schemaVersion=1;seq=($lastSeq+1);at=$now;operation=[int]$Receipt.operation;issueNumber=[int]$Receipt.issueNumber
            executionId=[string]$Receipt.executionId;generation=[int]$Receipt.generation;worker=[string]$Receipt.worker
            event=$Event;phase=$Phase;level=$Level;summary=(ConvertTo-ProgressSummary -Text $Summary)
        }
        $json = ([pscustomobject]$entry | ConvertTo-Json -Compress -Depth 6) + "`n"
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        $stream = New-Object System.IO.FileStream($path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        Add-Member -InputObject $Receipt -NotePropertyName progressLastEventAt -NotePropertyValue $now -Force
        Add-Member -InputObject $Receipt -NotePropertyName progressEventCount -NotePropertyValue ($lastSeq+1) -Force
        return [pscustomobject]$entry
    } catch {
        $message = ConvertTo-ProgressSummary -Text ([string]$_.Exception.Message)
        try { Add-Content -LiteralPath ([string]$Receipt.logPath) -Value "`nprogress_error=$message" -Encoding UTF8 } catch {}
        return $null
    } finally { $lock.Dispose() }
}

function Read-ExecutionProgressEvents {
    param([Parameter(Mandatory)]$Receipt,[int]$AfterSeq=0)
    $path = Get-ExecutionProgressPath -Receipt $Receipt
    Assert-PathWithinRoot -Path $path -Root ([string]$Receipt.artifactPath) | Out-Null
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $events=@()
    foreach($line in @((Read-SharedTextFile -Path $path) -split "`r?`n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})) {
        try { $e=$line|ConvertFrom-Json -ErrorAction Stop; if([int]$e.seq -gt $AfterSeq){$events += $e} } catch {}
    }
    return @($events | Sort-Object {[int]$_.seq})
}

function ConvertFrom-GptProgressLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    try { $item=$Line|ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    if($null -eq $item -or $item.PSObject.Properties.Name -notcontains 'type'){return @()}
    $events=@(); $type=[string]$item.type;$payload=$null
    if($item.PSObject.Properties.Name -contains 'item'){$payload=$item.item}
    $payloadType=if($null -ne $payload -and $payload.PSObject.Properties.Name -contains 'type'){[string]$payload.type}else{''}
    if($type -eq 'item.started' -and $payloadType -eq 'command_execution') {
        $command=if($payload.PSObject.Properties.Name -contains 'command'){[string]$payload.command}else{''}
        $events += [pscustomobject]@{event='command_started';phase='implementation';level='info';summary=('command started: ' + (ConvertTo-ProgressSummary -Text $command))}
    } elseif($type -eq 'item.completed' -and $payloadType -eq 'command_execution') {
        $summary='command completed'; if($payload.PSObject.Properties.Name -contains 'exit_code'){$summary += ' exit=' + [string]$payload.exit_code}
        $events += [pscustomobject]@{event='command_completed';phase='implementation';level='info';summary=$summary}
    } elseif($type -eq 'item.completed' -and $payloadType -eq 'file_change') {
        $path=''; if($payload.PSObject.Properties.Name -contains 'path'){$path=[string]$payload.path}elseif($payload.PSObject.Properties.Name -contains 'changes'){$path=(@($payload.changes|ForEach-Object{[string]$_.path}) -join ', ')}
        $events += [pscustomobject]@{event='file_changed';phase='implementation';level='info';summary=('file changed: ' + (ConvertTo-ProgressSummary -Text $path))}
    } elseif($type -eq 'item.completed' -and $payloadType -eq 'agent_message') {
        $messageText=if($payload.PSObject.Properties.Name -contains 'text'){[string]$payload.text}else{''}
        $message=ConvertTo-ProgressSummary -Text $messageText; if($message.Length -gt 160){$message=$message.Substring(0,160)}
        if(-not [string]::IsNullOrWhiteSpace($message)){$events += [pscustomobject]@{event='worker_output_activity';phase='implementation';level='info';summary=('agent update: ' + $message)}}
    } elseif($type -in @('turn.started','turn.completed','turn.failed')) {
        $level=if($type -eq 'turn.failed'){'warning'}else{'info'}
        $events += [pscustomobject]@{event='worker_output_activity';phase='implementation';level=$level;summary=($type -replace '\.',' ')}
    }
    return @($events)
}

function Get-ExecutionObservableState {
    param([Parameter(Mandatory)][string]$RepoPath)
    $head=$null;$status='';$ahead=$null;$behind=$null
    try{$head=Get-GitHead -Path $RepoPath}catch{}
    try{$worktree=Get-GitWorktreeStatus -Path $RepoPath;$status=[string]$worktree.Raw}catch{}
    try{$ab=Get-GitAheadBehind -Path $RepoPath;$ahead=$ab.ahead;$behind=$ab.behind}catch{}
    $files=@($status -split "`r?`n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | ForEach-Object { if($_.Length -gt 3){$_.Substring(3).Trim()}else{$_.Trim()} } | Sort-Object -Unique)
    return [pscustomobject]@{head=$head;worktreeClean=[string]::IsNullOrWhiteSpace($status);status=$status;files=$files;ahead=$ahead;behind=$behind}
}

function Format-ExecutionProgressLine {
    param([Parameter(Mandatory)]$Event)
    $time='--:--:--';try{$time=([DateTime]::Parse([string]$Event.at).ToLocalTime()).ToString('HH:mm:ss')}catch{}
    $label=switch([string]$Event.event){'worker_process_started'{'START'}'file_changed'{'FILE'}'command_started'{'COMMAND'}'command_completed'{'COMMAND'}'test_started'{'TEST'}'test_completed'{'TEST'}'commit_detected'{'COMMIT'}'push_detected'{'PUSH'}'heartbeat'{'RUNNING'}'worker_exited'{'EXIT'}'operation_terminal'{'TERMINAL'}default{([string]$Event.event).ToUpperInvariant()}}
    return ('[ORH][{0}] {1,-9} {2}' -f $time,$label,(ConvertTo-ProgressSummary -Text ([string]$Event.summary)))
}

function Get-WatchNextAction {
    param([Parameter(Mandatory)]$Receipt,[string]$Status)
    if([string]::IsNullOrWhiteSpace($Status)){$Status=[string]$Receipt.status}
    if($Status -notin @('completed','completed_ci_pending','completed_ci_unavailable')){if($Receipt.PSObject.Properties.Name -contains 'verificationProvenance' -and [string]$Receipt.verificationProvenance -eq 'git_postflight_without_worker_result'){return 'manual_verification'};return 'stop'}
    if([int]$Receipt.operation -eq 1){if([string]$Receipt.worker -eq 'grok'){return 'review'};return 'opus_end_review'}
    if([int]$Receipt.operation -eq 2){return 'sonnet_end_review'}
    return 'report'
}
