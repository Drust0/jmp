# jmp

I was tired of `cd`'ing arround my filesystem. I could've just defined
some shell aliases on my `.shellprofile` but they are awkward to mantain.
As such I made a simple utility that allows one to move to recorded directories.

## Usage

`jmp` keeps a list of files on a `jumptable`, when you run:
```
jmp somefile
```
It will fuzzily search for a file on that table by comparing the `somefile`
string to the **basename** of the file. The comparison algorithm is such
that you probabily only need to type `som` and it will match.

You can quickly add any path to your `jumptable` by running:
```
jmp -a path/to/your/directory/here
```

You can remove a path from the table with:
```
jmp -d path/to/remove
```

And thats it.

## How it works

The distance between two strings is the cheapest path, by deleting
and inserting characters where, deleting a character at
position `k` costs `1/k`. *(Insertions cost the same as if you deleted
the character you just inserted.)* This algorithm favors matching
prefixes of a string, the distance between `ta` and `table`
is just `0.78`, but between `ble` and `table` it is `1.50` despite
having a greater number of character matches.

If you want to test the comparison algorithm you can run
```
jmp -c string1 string2
```

Aditionally you can see how your pattern measures against your table by running
```
jmp -C patternhere
```
