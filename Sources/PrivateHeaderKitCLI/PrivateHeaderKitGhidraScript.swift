// The release installs a standalone executable, so the headless script travels
// with the CLI and is materialized only in the owned analysis workspace.
let privateHeaderKitGhidraScript = #"""
import ghidra.app.util.headless.HeadlessScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolUtilities;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Set;

public class PHKDecompile extends HeadlessScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        Path work = Path.of(args[1]);
        try {
            if (args[0].equals("select")) {
                String requested = Files.readString(work.resolve("symbol.txt"));
                String imported = SymbolUtilities.replaceInvalidChars(requested, true);
                Set<Address> addresses = new HashSet<>();
                // Select before analysis renames C++ and Objective-C symbols.
                for (Symbol symbol : currentProgram.getSymbolTable().getAllSymbols(true)) {
                    monitor.checkCancelled();
                    if (!symbol.isExternal() && symbol.getName().equals(imported)) {
                        addresses.add(symbol.getAddress());
                    }
                }
                if (addresses.isEmpty()) throw new Exception("Symbol not found: " + requested);
                if (addresses.size() != 1) throw new Exception("Symbol is ambiguous: " + requested);
                Files.writeString(work.resolve("address.txt"), addresses.iterator().next().toString());
            } else {
                Address address = toAddr(Files.readString(work.resolve("address.txt")));
                Function function = currentProgram.getFunctionManager().getFunctionAt(address);
                if (function == null || function.isExternal()) {
                    throw new Exception("Selected symbol is not a recognized function");
                }
                DecompInterface decompiler = new DecompInterface();
                try {
                    if (!decompiler.openProgram(currentProgram)) throw new Exception(decompiler.getLastMessage());
                    DecompileResults result = decompiler.decompileFunction(function, Integer.parseInt(args[2]), monitor);
                    if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
                        throw new Exception("Decompilation failed: " + result.getErrorMessage());
                    }
                    String note = "// Ghidra pseudocode; types and signatures may be inferred.\n";
                    if (analysisTimeoutOccurred()) {
                        note += "// Analysis reached its time limit; increase --timeout for more context.\n";
                    }
                    Files.writeString(work.resolve("code.c"), note + result.getDecompiledFunction().getC());
                } finally {
                    decompiler.dispose();
                }
            }
        } catch (Exception error) {
            Files.writeString(work.resolve("error.txt"), error.toString());
            setHeadlessContinuationOption(HeadlessContinuationOption.ABORT_AND_DELETE);
        }
    }
}
"""#
