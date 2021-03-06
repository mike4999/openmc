module cmfd_loss_operator

# ifdef PETSC

  implicit none
  private
  public :: init_M_operator, build_loss_matrix, destroy_M_operator

# include <finclude/petsc.h90>

  integer  :: nx   ! maximum number of x cells
  integer  :: ny   ! maximum number of y cells
  integer  :: nz   ! maximum number of z cells
  integer  :: ng   ! maximum number of groups
  integer  :: ierr ! petsc error code

  type, public :: loss_operator
    Mat      :: M      ! petsc matrix for neutronic loss operator
    integer  :: n      ! dimensions of matrix
    integer  :: nnz    ! max number of nonzeros
    integer  :: localn ! local size on proc
    integer, allocatable :: d_nnz(:) ! vector of diagonal preallocation
    integer, allocatable :: o_nnz(:) ! vector of off-diagonal preallocation
  end type loss_operator

  logical :: adjoint_calc = .false. ! adjoint calculation

contains

!===============================================================================
! INIT_M_OPERATOR
!===============================================================================

  subroutine init_M_operator(this)

    type(loss_operator) :: this

    ! get indices
    call get_M_indices(this)

    ! get preallocation
    call preallocate_loss_matrix(this)

    ! set up M operator
    call MatCreateAIJ(PETSC_COMM_WORLD, this%localn, this%localn, PETSC_DECIDE,&
         PETSC_DECIDE, PETSC_NULL_INTEGER, this%d_nnz, PETSC_NULL_INTEGER, &
         this%o_nnz, this%M,ierr)
    call MatSetOption(this%M, MAT_NEW_NONZERO_LOCATIONS, PETSC_TRUE, ierr)
    call MatSetOption(this%M, MAT_IGNORE_ZERO_ENTRIES, PETSC_TRUE, ierr)

  end subroutine init_M_operator

!===============================================================================
! GET_M_INDICES
!===============================================================================

  subroutine get_M_indices(this)

    use global,  only: cmfd, cmfd_coremap

    type(loss_operator) :: this

    ! get maximum number of cells in each direction
    nx = cmfd%indices(1)
    ny = cmfd%indices(2)
    nz = cmfd%indices(3)
    ng = cmfd%indices(4)

    ! get number of nonzeros
    this%nnz = 7 + ng - 1

    ! calculate dimensions of matrix
    if (cmfd_coremap) then
      this%n = cmfd % mat_dim * ng
    else
      this%n = nx*ny*nz*ng
    end if

  end subroutine get_M_indices

!===============================================================================
! PREALLOCATE_LOSS_MATRIX
!===============================================================================

  subroutine preallocate_loss_matrix(this)

    use constants,  only: CMFD_NOACCEL
    use global,     only: cmfd, cmfd_coremap

    type(loss_operator) :: this

    integer :: rank          ! rank of processor
    integer :: sizen         ! number of procs
    integer :: i             ! iteration counter for x
    integer :: j             ! iteration counter for y
    integer :: k             ! iteration counter for z
    integer :: g             ! iteration counter for groups
    integer :: l             ! iteration counter for leakages
    integer :: h             ! energy group when doing scattering
    integer :: n             ! the extent of the matrix
    integer :: irow          ! row counter
    integer :: bound(6)      ! vector for comparing when looking for bound
    integer :: xyz_idx       ! index for determining if x,y or z leakage
    integer :: dir_idx       ! index for determining - or + face of cell
    integer :: neig_idx(3)   ! spatial indices of neighbour
    integer :: nxyz(3,2)     ! single vector containing bound. locations
    integer :: shift_idx     ! parameter to shift index by +1 or -1
    integer :: row_start     ! index of local starting row
    integer :: row_end       ! index of local final row
    integer :: neig_mat_idx  ! matrix index of neighbor cell
    integer :: scatt_mat_idx ! matrix index for h-->g scattering terms

    ! initialize size and rank
    sizen = 0
    rank = 0

    ! get rank and max rank of procs
    call MPI_COMM_RANK(PETSC_COMM_WORLD, rank, ierr)
    call MPI_COMM_SIZE(PETSC_COMM_WORLD, sizen, ierr)

    ! get local problem size
    n = this%n

    ! determine local size, divide evenly between all other procs
    this%localn = n/(sizen)
        
    ! add 1 more if less proc id is less than mod
    if (rank < mod(n,sizen)) this%localn = this%localn + 1

    ! determine local starting row
    row_start = 0
    if (rank < mod(n,sizen)) then
      row_start = rank*(n/sizen+1)
    else
      row_start = min(mod(n,sizen)*(n/sizen+1) + &
           (rank - mod(n,sizen))*(n/sizen),n) 
    end if

    ! determine local final row
    row_end = row_start + this%localn - 1

    ! allocate counters
    if (.not. allocated(this%d_nnz)) allocate(this%d_nnz(row_start:row_end))
    if (.not. allocated(this%o_nnz)) allocate(this%o_nnz(row_start:row_end))
    this % d_nnz = 0
    this % o_nnz = 0

    ! create single vector of these indices for boundary calculation
    nxyz(1,:) = (/1,nx/)
    nxyz(2,:) = (/1,ny/)
    nxyz(3,:) = (/1,nz/)

    ! begin loop around local rows
    ROWS: do irow = row_start,row_end

      ! initialize counters 
      this%d_nnz(irow) = 1 ! already add in matrix diagonal
      this%o_nnz(irow) = 0

      ! get location indices
      call matrix_to_indices(irow, g, i, j, k)

      ! create boundary vector
      bound = (/i,i,j,j,k,k/)

      ! begin loop over leakages
      LEAK: do l = 1,6

        ! define (x,y,z) and (-,+) indices
        xyz_idx = int(ceiling(real(l)/real(2)))  ! x=1, y=2, z=3
        dir_idx = 2 - mod(l,2) ! -=1, +=2

        ! calculate spatial indices of neighbor
        neig_idx = (/i,j,k/)                ! begin with i,j,k
        shift_idx = -2*mod(l,2) +1          ! shift neig by -1 or +1
        neig_idx(xyz_idx) = shift_idx + neig_idx(xyz_idx)

        ! check for global boundary
        if (bound(l) /= nxyz(xyz_idx,dir_idx)) then

          ! check for coremap 
          if (cmfd_coremap) then

            ! check for neighbor that is non-acceleartred
            if (cmfd % coremap(neig_idx(1),neig_idx(2),neig_idx(3)) /= &
                 CMFD_NOACCEL) then

              ! get neighbor matrix index
              call indices_to_matrix(g,neig_idx(1), neig_idx(2), & 
                   neig_idx(3), neig_mat_idx)

              ! record nonzero
              if (((neig_mat_idx-1) >= row_start) .and. &
                   ((neig_mat_idx-1) <= row_end)) then
                this%d_nnz(irow) = this%d_nnz(irow) + 1
              else
                this%o_nnz(irow) = this%o_nnz(irow) + 1
              end if

            end if

          else

            ! get neighbor matrix index
            call indices_to_matrix(g, neig_idx(1), neig_idx(2), neig_idx(3), &
                 neig_mat_idx)

            ! record nonzero
            if (((neig_mat_idx-1) >= row_start) .and. &
                 ((neig_mat_idx-1) <= row_end)) then
              this%d_nnz(irow) = this%d_nnz(irow) + 1
            else
              this%o_nnz(irow) = this%o_nnz(irow) + 1
            end if

          end if

        end if

      end do LEAK

      ! begin loop over off diagonal in-scattering
      SCATTR: do h = 1, ng

        ! cycle though if h=g
        if (h == g) cycle

        ! get neighbor matrix index
        call indices_to_matrix(h, i, j, k, scatt_mat_idx)

        ! record nonzero
        if (((scatt_mat_idx-1) >= row_start) .and. &
             ((scatt_mat_idx-1) <= row_end)) then
          this%d_nnz(irow) = this%d_nnz(irow) + 1
        else
          this%o_nnz(irow) = this%o_nnz(irow) + 1
        end if

      end do SCATTR

    end do ROWS

  end subroutine preallocate_loss_matrix

!===============================================================================
! BUILD_LOSS_MATRIX creates the matrix representing loss of neutrons
!===============================================================================

  subroutine build_loss_matrix(this, adjoint)

    use constants,  only: CMFD_NOACCEL, ZERO
    use global,     only: cmfd, cmfd_coremap, cmfd_write_matrices

    type(loss_operator) :: this
    logical, optional :: adjoint    ! set up the adjoint

    integer :: nxyz(3,2)            ! single vector containing bound. locations
    integer :: i                    ! iteration counter for x
    integer :: j                    ! iteration counter for y
    integer :: k                    ! iteration counter for z
    integer :: g                    ! iteration counter for groups
    integer :: l                    ! iteration counter for leakages
    integer :: h                    ! energy group when doing scattering
    integer :: neig_mat_idx         ! matrix index of neighbor cell
    integer :: scatt_mat_idx        ! matrix index for h-->g scattering terms
    integer :: bound(6)             ! vector for comparing when looking for bound
    integer :: xyz_idx              ! index for determining if x,y or z leakage
    integer :: dir_idx              ! index for determining - or + face of cell
    integer :: neig_idx(3)          ! spatial indices of neighbour
    integer :: shift_idx            ! parameter to shift index by +1 or -1
    integer :: row_start            ! the first local row on the processor
    integer :: row_finish           ! the last local row on the processor
    integer :: irow                 ! iteration counter over row
    real(8) :: totxs                ! total macro cross section
    real(8) :: scattxsgg            ! scattering macro cross section g-->g
    real(8) :: scattxshg            ! scattering macro cross section h-->g
    real(8) :: dtilde(6)            ! finite difference coupling parameter
    real(8) :: dhat(6)              ! nonlinear coupling parameter
    real(8) :: hxyz(3)              ! cell lengths in each direction
    real(8) :: jn                   ! direction dependent leakage coeff to neig
    real(8) :: jo(6)                ! leakage coeff in front of cell flux
    real(8) :: jnet                 ! net leakage from jo
    real(8) :: val                  ! temporary variable before saving to 

    ! check for adjoint
    if (present(adjoint)) adjoint_calc = adjoint 

    ! create single vector of these indices for boundary calculation
    nxyz(1,:) = (/1,nx/)
    nxyz(2,:) = (/1,ny/)
    nxyz(3,:) = (/1,nz/)

    ! initialize row start and finish
    row_start = 0
    row_finish = 0

    ! get row bounds for this processor
    call MatGetOwnershipRange(this%M, row_start, row_finish, ierr)

    ! begin iteration loops
    ROWS: do irow = row_start, row_finish-1

      ! get indices for that row
      call matrix_to_indices(irow, g, i, j, k)

      ! retrieve cell data
      totxs = cmfd%totalxs(g,i,j,k)
      scattxsgg = cmfd%scattxs(g,g,i,j,k)
      dtilde = cmfd%dtilde(:,g,i,j,k)
      hxyz = cmfd%hxyz(:,i,j,k)

      ! check and get dhat
      if (allocated(cmfd%dhat)) then
        dhat = cmfd%dhat(:,g,i,j,k)
      else
        dhat = ZERO
      end if

      ! create boundary vector 
      bound = (/i,i,j,j,k,k/)

      ! begin loop over leakages
      ! 1=-x, 2=+x, 3=-y, 4=+y, 5=-z, 6=+z 
      LEAK: do l = 1,6

        ! define (x,y,z) and (-,+) indices
        xyz_idx = int(ceiling(real(l)/real(2)))  ! x=1, y=2, z=3
        dir_idx = 2 - mod(l,2) ! -=1, +=2

        ! calculate spatial indices of neighbor
        neig_idx = (/i,j,k/)                ! begin with i,j,k
        shift_idx = -2*mod(l,2) +1          ! shift neig by -1 or +1
        neig_idx(xyz_idx) = shift_idx + neig_idx(xyz_idx)

        ! check for global boundary
        if (bound(l) /= nxyz(xyz_idx,dir_idx)) then

          ! check for core map
          if (cmfd_coremap) then

            ! check that neighbor is not reflector
            if (cmfd % coremap(neig_idx(1),neig_idx(2),neig_idx(3)) /= &
                 CMFD_NOACCEL) then

              ! compute leakage coefficient for neighbor
              jn = -dtilde(l) + shift_idx*dhat(l)

              ! get neighbor matrix index
              call indices_to_matrix(g, neig_idx(1), neig_idx(2), neig_idx(3), &
                   neig_mat_idx)

              ! compute value and record to bank
              val = jn/hxyz(xyz_idx)

              ! record value in matrix
              call MatSetValue(this%M, irow, neig_mat_idx-1, val, &
                   INSERT_VALUES, ierr)

            end if

          else

            ! compute leakage coefficient for neighbor
            jn = -dtilde(l) + shift_idx*dhat(l)

            ! get neighbor matrix index
            call indices_to_matrix(g, neig_idx(1), neig_idx(2), neig_idx(3), &
                 neig_mat_idx)

            ! compute value and record to bank
            val = jn/hxyz(xyz_idx)

            ! record value in matrix
            call MatSetValue(this%M, irow, neig_mat_idx-1, val, &
                 INSERT_VALUES, ierr)

          end if

        end if

        ! compute leakage coefficient for target
        jo(l) = shift_idx*dtilde(l) + dhat(l)

      end do LEAK

      ! calate net leakage coefficient for target
      jnet = (jo(2) - jo(1))/hxyz(1) + (jo(4) - jo(3))/hxyz(2) + &
           (jo(6) - jo(5))/hxyz(3)

      ! calculate loss of neutrons
      val = jnet + totxs - scattxsgg

      ! record diagonal term
      call MatSetValue(this%M, irow, irow, val, INSERT_VALUES, ierr)

      ! begin loop over off diagonal in-scattering
      SCATTR: do h = 1, ng

        ! cycle though if h=g
        if (h == g) cycle

        ! get neighbor matrix index
        call indices_to_matrix(h, i, j, k, scatt_mat_idx)

        ! get scattering macro xs
        scattxshg = cmfd%scattxs(h, g, i, j, k)

        ! record value in matrix (negate it)
        val = -scattxshg

        ! check for adjoint and bank value
        if (adjoint_calc) then
          call MatSetValue(this%M, scatt_mat_idx-1, irow, val, &
               INSERT_VALUES, ierr)
        else
          call MatSetValue(this%M, irow, scatt_mat_idx-1, val, &
               INSERT_VALUES, ierr)
        end if

      end do SCATTR

    end do ROWS 

    ! assemble matrix
    call MatAssemblyBegin(this%M, MAT_FLUSH_ASSEMBLY, ierr)
    call MatAssemblyEnd(this%M, MAT_FINAL_ASSEMBLY, ierr)

    ! print out operator to file
    if (cmfd_write_matrices) call print_M_operator(this)

  end subroutine build_loss_matrix

!===============================================================================
! INDICES_TO_MATRIX takes (x,y,z,g) indices and computes location in matrix
!===============================================================================

  subroutine indices_to_matrix(g, i, j, k, matidx)

    use global,  only: cmfd, cmfd_coremap

    integer :: matidx ! the index location in matrix
    integer :: i      ! current x index
    integer :: j      ! current y index
    integer :: k      ! current z index
    integer :: g      ! current group index

    ! check if coremap is used
    if (cmfd_coremap) then

      ! get idx from core map
      matidx = ng*(cmfd % coremap(i,j,k)) - (ng - g)

    else

      ! compute index
      matidx = g + ng*(i - 1) + ng*nx*(j - 1) + ng*nx*ny*(k - 1)

    end if

  end subroutine indices_to_matrix

!===============================================================================
! MATRIX_TO_INDICES
!===============================================================================

  subroutine matrix_to_indices(irow, g, i, j, k)

    use global,  only: cmfd, cmfd_coremap

    integer :: i     ! iteration counter for x
    integer :: j     ! iteration counter for y
    integer :: k     ! iteration counter for z
    integer :: g     ! iteration counter for groups
    integer :: irow  ! iteration counter over row (0 reference)

    ! check for core map
    if (cmfd_coremap) then

      ! get indices from indexmap
      g = mod(irow, ng) + 1
      i = cmfd % indexmap(irow/ng+1,1)
      j = cmfd % indexmap(irow/ng+1,2)
      k = cmfd % indexmap(irow/ng+1,3)

    else

      ! compute indices
      g = mod(irow, ng) + 1
      i = mod(irow, ng*nx)/ng + 1
      j = mod(irow, ng*nx*ny)/(ng*nx)+ 1
      k = mod(irow, ng*nx*ny*nz)/(ng*nx*ny) + 1

    end if

  end subroutine matrix_to_indices

!===============================================================================
! PRINT_M_OPERATOR
!===============================================================================

  subroutine print_M_operator(this)

    type(loss_operator) :: this

    PetscViewer :: viewer

    ! write out matrix in binary file (debugging)
    if (adjoint_calc) then
      call PetscViewerBinaryOpen(PETSC_COMM_WORLD, 'adj_lossmat.bin', &
           FILE_MODE_WRITE, viewer, ierr)
    else
      call PetscViewerBinaryOpen(PETSC_COMM_WORLD, 'lossmat.bin', &
           FILE_MODE_WRITE, viewer, ierr)
    end if
    call MatView(this%M, viewer, ierr)
    call PetscViewerDestroy(viewer, ierr)

  end subroutine print_M_operator

!==============================================================================
! DESTROY_M_OPERATOR
!==============================================================================

  subroutine destroy_M_operator(this)

    type(loss_operator) :: this

    ! deallocate matrix
    call MatDestroy(this%M, ierr)

    ! deallocate other parameters
    if (allocated(this%d_nnz)) deallocate(this%d_nnz)
    if (allocated(this%o_nnz)) deallocate(this%o_nnz)

  end subroutine destroy_M_operator

# endif

end module cmfd_loss_operator
