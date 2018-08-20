@echo off
if _%2==_ goto error
if not _%3==_ goto error
set tens=
set ones=
for %%v in (0 1) do  if %1==%%v goto First%%v
if %1==2 set tens=twenty 
if %1==3 set tens=thirty 
if %1==4 set tens=forty 
if %1==5 set tens=fifty 
if %1==6 set tens=sixty 
if %1==7 set tens=seventy 
if %1==8 set tens=eighty 
if %1==9 set tens=ninety 
if not _%tens%==_ goto ones

:error
echo Please enter exactly 2 digits.
goto end

:First1
if %2==0 set tens=ten
if %2==1 set tens=eleven
if %2==2 set tens=twelve
if %2==3 set tens=thirteen
if %2==4 set tens=fourteen
if %2==5 set tens=fifteen
if %2==6 set tens=sixteen
if %2==7 set tens=seventeen
if %2==8 set tens=eighteen
if %2==9 set tens=nineteen
goto done

:First0
set ones=zero
if %2==0 goto done
set ones=

:ones
if %2==0 set ones= 
if %2==1 set ones=one
if %2==2 set ones=two
if %2==3 set ones=three
if %2==4 set ones=four
if %2==5 set ones=five
if %2==6 set ones=six
if %2==7 set ones=seven
if %2==8 set ones=eight
if %2==9 set ones=nine
if _%ones%_==__ goto error

:done
if _%tens%%ones==_ goto error
echo %tens%%ones%
set tens=
set ones=
:end