>>         git commit -m "feat(entra): streamline pipeline attribute check in Get-ToolkitGroupMember tests and pass quality gate"
>>         git push origin feature/notebooklm-module-books
>>
>>         Write-Host "Get-ToolkitGroupMember fully tested, verified, and pushed successfully!" -ForegroundColor Green
>>     }
>> } else {
>>     throw "Export aborted! Entra Pester test suite failed with $($entraTest.FailedCount) failures."
>> }
Running Entra Pester quality gate...

Running tests from 3 files.
[+] C:\Users\jchristy\Documents\GitHub\O365-Management\Modules\O365Toolkit.Entra\Tests\Get-ToolkitGroup.Tests.ps1 70ms
[-] Get-ToolkitGroupMember Unit Tests.Parameter Validation and Mocking.Should define GroupId parameter with pipeline support 3ms
 RuntimeException: You cannot call a method on a null-valued expression.
 at <ScriptBlock>, C:\Users\jchristy\Documents\GitHub\O365-Management\Modules\O365Toolkit.Entra\Tests\Get-ToolkitGroupMember.Tests.ps1:9
[+] C:\Users\jchristy\Documents\GitHub\O365-Management\Modules\O365Toolkit.Entra\Tests\GetToolkitUser.Tests.ps1 418ms
Tests completed in 561ms
Tests Passed: 10, Failed: 1, Skipped: 0, Inconclusive: 0, NotRun: 0
Exception:
Line |
  33 |      throw "Export aborted! Entra Pester test suite failed with $($ent …
     |      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | Export aborted! Entra Pester test suite failed with 1 failures.
PS C:\Users\jchristy\Documents\GitHub\O365-Management>
