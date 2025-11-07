# Pre-Commit Checklist for NVMe GDA

Before running `./commit-nvme-gda.sh`, verify:

## Code Quality

- [ ] All source files compile without errors
- [ ] No debug printf statements left in production code
- [ ] Error handling is comprehensive
- [ ] Memory leaks checked (queues, DMA, etc.)
- [ ] Proper cleanup in error paths

## Testing

- [ ] Kernel driver loads without errors
- [ ] Device node `/dev/nvme_gda0` created
- [ ] All IOCTLs tested and working
- [ ] Memory mappings verified (SQE, CQE, Doorbell)
- [ ] HSA initialization successful
- [ ] Basic HIP test passes
- [ ] No kernel panics or oopses

## Documentation

- [ ] All README files updated
- [ ] Architecture documented in markdown files
- [ ] Build instructions in QUICKSTART.md
- [ ] Test results in TESTING_STATUS.md
- [ ] Known issues documented
- [ ] API documentation complete

## Code Organization

- [ ] Source code in nvme-gda/ directory
- [ ] Documentation in markdown files
- [ ] Test programs in tests/ directory
- [ ] Build files (Makefile, CMakeLists.txt) present
- [ ] No temporary files included

## Git Hygiene

- [ ] `.gitignore` updated if needed
- [ ] No compiled binaries in commit
- [ ] No large test data files
- [ ] No personal configuration files
- [ ] Sensitive information removed

## Kernel Module

- [ ] Module compiles for target kernel (6.8.0-87-generic)
- [ ] No warnings during compilation
- [ ] Module loads and unloads cleanly
- [ ] Proper module parameters documented
- [ ] Module dependencies listed

## Userspace Library

- [ ] Library compiles with CMake
- [ ] All dependencies found (HSA, HIP)
- [ ] Headers properly installed
- [ ] Test programs link correctly

## GPU Device Code

- [ ] Compiles with -fgpu-rdc
- [ ] extern "C" linkage for all device functions
- [ ] Static library builds successfully
- [ ] Links with test programs

## Commit Message

- [ ] Descriptive title (feat: ...)
- [ ] Detailed description of changes
- [ ] Lists all major components
- [ ] Mentions testing status
- [ ] References documentation
- [ ] Notes future work

## Final Checks

- [ ] Ran `git status` to verify files
- [ ] Reviewed `git diff` for unintended changes
- [ ] No merge conflicts
- [ ] Branch is up to date
- [ ] Ready for code review

---

## Quick Test Commands

```bash
# Test kernel driver
cd nvme-gda/nvme_gda_driver
make clean && make
sudo insmod nvme_gda.ko nvme_pci_dev=0000:01:00.0
lsmod | grep nvme_gda
ls -l /dev/nvme_gda0
sudo rmmod nvme_gda

# Test userspace build
cd nvme-gda
mkdir -p build && cd build
cmake .. && make -j4

# Test basic HIP
cd gda-experiments
/opt/rocm/bin/hipcc -o test_hip_basic test_hip_basic.hip
./test_hip_basic
```

---

## Running the Commit Script

```bash
cd /home/stebates/Projects/rocm-axiio/gda-experiments
./commit-nvme-gda.sh
```

The script will:
1. Show all files to be committed
2. Display summary statistics
3. Ask for confirmation
4. Show the commit message
5. Ask for final confirmation
6. Commit the changes
7. Show the commit details

---

## After Commit

1. **Verify the commit**:
   ```bash
   git show
   git log -1 --stat
   ```

2. **Test from clean state**:
   ```bash
   git stash
   git checkout HEAD
   # Try building everything
   git stash pop
   ```

3. **Push to remote** (when ready):
   ```bash
   git push origin <your-branch>
   ```

4. **Create PR** (if applicable):
   - Include link to documentation
   - Reference test results
   - Add screenshots of working tests
   - Tag reviewers

---

## Rollback if Needed

If you need to undo the commit:

```bash
# Undo commit but keep changes
git reset --soft HEAD^

# Undo commit and changes (careful!)
git reset --hard HEAD^
```

---

## Success Criteria

After commit, someone else should be able to:
- Clone the repository
- Follow QUICKSTART.md
- Build everything
- Load the driver
- Run basic tests
- See the same results

---

**Ready to commit? Run `./commit-nvme-gda.sh`**

