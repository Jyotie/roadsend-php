<?php
var_dump(strpos("test string", "test"));
var_dump(strpos("test string", "string"));
var_dump(strpos("test string", "strin"));
var_dump(strpos("test string", "t s"));
var_dump(strpos("test string", "g"));
var_dump(strpos("te".chr(0)."st", chr(0)));
var_dump(strpos("tEst", "test"));
var_dump(strpos("teSt", "test"));
var_dump(@strpos("", ""));
var_dump(@strpos("a", ""));
var_dump(@strpos("", "a"));
var_dump(@strpos("\\\\a", "\\a"));
?>