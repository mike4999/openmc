module eigenvalue

#ifdef MPI
  use mpi
#endif

  use cmfd_execute, only: cmfd_init_batch, execute_cmfd
  use constants,    only: ZERO
  use error,        only: fatal_error, warning
  use global
  use math,         only: t_percentile
  use mesh,         only: count_bank_sites
  use mesh_header,  only: StructuredMesh
  use output,       only: write_message, header, print_columns,              &
                          print_batch_keff, print_generation
  use physics,      only: transport
  use random_lcg,   only: prn, set_particle_seed, prn_skip
  use search,       only: binary_search
  use source,       only: get_source_particle
  use state_point,  only: write_state_point, replay_batch_history
  use string,       only: to_str
  use tally,        only: synchronize_tallies, setup_active_usertallies, &
                          reset_result
  use timing,       only: timer_start, timer_stop

#ifdef HDF5
  use hdf5_interface, only: hdf5_write_state_point
#endif

  private
  public :: run_eigenvalue

contains

!===============================================================================
! RUN_EIGENVALUE encompasses all the main logic where iterations are performed
! over the batches, generations, and histories in a k-eigenvalue calculation.
!===============================================================================

  subroutine run_eigenvalue()

    integer(8) :: i  ! index over individual particles

    if (master) call header("K EIGENVALUE SIMULATION", level=1)

    ! Allocate particle
    allocate(p)

    ! Display column titles
    call print_columns()

    ! Turn on inactive timer
    call timer_start(time_inactive)

    ! ==========================================================================
    ! LOOP OVER BATCHES
    BATCH_LOOP: do current_batch = 1, n_batches

      call initialize_batch()

      ! Handle restart runs
      if (restart_run .and. current_batch <= restart_batch) then
        call replay_batch_history()
        cycle BATCH_LOOP
      end if

      ! =======================================================================
      ! LOOP OVER GENERATIONS
      GENERATION_LOOP: do current_gen = 1, gen_per_batch

        call initialize_generation()

        ! Start timer for transport
        call timer_start(time_transport)

        ! ====================================================================
        ! LOOP OVER PARTICLES
        PARTICLE_LOOP: do i = 1, work

          ! grab source particle from bank
          call get_source_particle(i)

          ! transport particle
          call transport()

        end do PARTICLE_LOOP

        ! Accumulate time for transport
        call timer_stop(time_transport)

        ! Distribute fission bank across processors evenly
        call timer_start(time_bank)
        call synchronize_bank()
        call timer_stop(time_bank)

        ! Calculate shannon entropy
        if (entropy_on) call shannon_entropy()

        ! Write generation output
        if (master .and. current_gen /= gen_per_batch) call print_generation()

      end do GENERATION_LOOP

      call finalize_batch()

    end do BATCH_LOOP

    call timer_stop(time_active)

    ! ==========================================================================
    ! END OF RUN WRAPUP

    if (master) call header("SIMULATION FINISHED", level=1)

  end subroutine run_eigenvalue

!===============================================================================
! INITIALIZE_BATCH
!===============================================================================

  subroutine initialize_batch()

    message = "Simulating batch " // trim(to_str(current_batch)) // "..."
    call write_message(8)

    ! Reset total starting particle weight used for normalizing tallies
    total_weight = ZERO

    if (current_batch == n_inactive + 1) then
      ! Switch from inactive batch timer to active batch timer
      call timer_stop(time_inactive)
      call timer_start(time_active)

      ! Enable active batches (and tallies_on if it hasn't been enabled)
      active_batches = .true.
      tallies_on = .true.

      ! Add user tallies to active tallies list
      call setup_active_usertallies()
    end if

    ! check CMFD initialize batch
    if (cmfd_run) call cmfd_init_batch()

  end subroutine initialize_batch

!===============================================================================
! INITIALIZE_GENERATION
!===============================================================================

  subroutine initialize_generation()

    ! Reset number of fission bank sites
    n_bank = 0

    ! Count source sites if using uniform fission source weighting
    if (ufs) call count_source_for_ufs()

  end subroutine initialize_generation

!===============================================================================
! FINALIZE_BATCH handles synchronization and accumulation of tallies,
! calculation of Shannon entropy, getting single-batch estimate of keff, and
! turning on tallies when appropriate
!===============================================================================

  subroutine finalize_batch()

    integer :: i ! loop index for state point batches

    ! Collect tallies
    call timer_start(time_tallies)
    call synchronize_tallies()
    call timer_stop(time_tallies)

    ! Collect results and statistics
    call calculate_keff()

    ! Perform CMFD calculation if on
    if (cmfd_on) call execute_cmfd()

    ! Display output
    if (master) call print_batch_keff()

    ! Write out state point if it's been specified for this batch
    do i = 1, n_state_points
      if (current_batch == statepoint_batch(i)) then
        ! Create state point file
#ifdef HDF5
        call hdf5_write_state_point()
#else
        call write_state_point()
#endif
        exit
      end if
    end do

  end subroutine finalize_batch

!===============================================================================
! SYNCHRONIZE_BANK samples source sites from the fission sites that were
! accumulated during the generation. This routine is what allows this Monte
! Carlo to scale to large numbers of processors where other codes cannot.
!===============================================================================

  subroutine synchronize_bank()

    integer    :: i            ! loop indices
    integer    :: j            ! loop indices
    integer(8) :: start        ! starting index in global bank
    integer(8) :: finish       ! ending index in global bank
    integer(8) :: total        ! total sites in global fission bank
    integer(8) :: index_temp   ! index in temporary source bank
    integer(8) :: sites_needed ! # of sites to be sampled
    real(8)    :: p_sample     ! probability of sampling a site
    type(Bank), save, allocatable :: &
         & temp_sites(:)       ! local array of extra sites on each node

#ifdef MPI
    integer    :: n            ! number of sites to send/recv
    integer    :: neighbor     ! processor to send/recv data from
    integer    :: request(20)  ! communication request for send/recving sites
    integer    :: n_request    ! number of communication requests
    integer(8) :: index_local  ! index in local source bank
    integer(8), save, allocatable :: &
         & bank_position(:)    ! starting positions in global source bank
#endif

    ! In order to properly understand the fission bank algorithm, you need to
    ! think of the fission and source bank as being one global array divided
    ! over multiple processors. At the start, each processor has a random amount
    ! of fission bank sites -- each processor needs to know the total number of
    ! sites in order to figure out the probability for selecting
    ! sites. Furthermore, each proc also needs to know where in the 'global'
    ! fission bank its own sites starts in order to ensure reproducibility by
    ! skipping ahead to the proper seed.

#ifdef MPI
    start = 0_8
    call MPI_EXSCAN(n_bank, start, 1, MPI_INTEGER8, MPI_SUM, & 
         MPI_COMM_WORLD, mpi_err)
    finish = start + n_bank
    total = finish
    call MPI_BCAST(total, 1, MPI_INTEGER8, n_procs - 1, & 
         MPI_COMM_WORLD, mpi_err)

#else
    start  = 0_8
    finish = n_bank
    total  = n_bank
#endif

    ! If there are not that many particles per generation, it's possible that no
    ! fission sites were created at all on a single processor. Rather than add
    ! extra logic to treat this circumstance, we really want to ensure the user
    ! runs enough particles to avoid this in the first place.

    if (n_bank == 0) then
      message = "No fission sites banked on processor " // to_str(rank)
      call fatal_error()
    end if

    ! Make sure all processors start at the same point for random sampling. Then
    ! skip ahead in the sequence using the starting index in the 'global'
    ! fission bank for each processor.

    call set_particle_seed(int((current_batch - 1)*gen_per_batch + &
         current_gen,8))
    call prn_skip(start)

    ! Determine how many fission sites we need to sample from the source bank
    ! and the probability for selecting a site.

    if (total < n_particles) then
      sites_needed = mod(n_particles,total)
    else
      sites_needed = n_particles
    end if
    p_sample = real(sites_needed,8)/real(total,8)

    call timer_start(time_bank_sample)

    ! ==========================================================================
    ! SAMPLE N_PARTICLES FROM FISSION BANK AND PLACE IN TEMP_SITES

    ! Allocate temporary source bank
    index_temp = 0_8
    if (.not. allocated(temp_sites)) allocate(temp_sites(3*work))

    do i = 1, int(n_bank,4)

      ! If there are less than n_particles particles banked, automatically add
      ! int(n_particles/total) sites to temp_sites. For example, if you need
      ! 1000 and 300 were banked, this would add 3 source sites per banked site
      ! and the remaining 100 would be randomly sampled.
      if (total < n_particles) then
        do j = 1, int(n_particles/total)
          index_temp = index_temp + 1
          temp_sites(index_temp) = fission_bank(i)
        end do
      end if

      ! Randomly sample sites needed
      if (prn() < p_sample) then
        index_temp = index_temp + 1
        temp_sites(index_temp) = fission_bank(i)
      end if
    end do

    ! At this point, the sampling of source sites is done and now we need to
    ! figure out where to send source sites. Since it is possible that one
    ! processor's share of the source bank spans more than just the immediate
    ! neighboring processors, we have to perform an ALLGATHER to determine the
    ! indices for all processors

#ifdef MPI
    ! First do an exclusive scan to get the starting indices for 
    start = 0_8
    call MPI_EXSCAN(index_temp, start, 1, MPI_INTEGER8, MPI_SUM, & 
         MPI_COMM_WORLD, mpi_err)
    finish = start + index_temp

    ! Allocate space for bank_position if this hasn't been done yet
    if (.not. allocated(bank_position)) allocate(bank_position(n_procs))
    call MPI_ALLGATHER(start, 1, MPI_INTEGER8, bank_position, 1, &
         MPI_INTEGER8, MPI_COMM_WORLD, mpi_err)
#else
    start  = 0_8
    finish = index_temp
#endif

    ! Now that the sampling is complete, we need to ensure that we have exactly
    ! n_particles source sites. The way this is done in a reproducible manner is
    ! to adjust only the source sites on the last processor.

    if (rank == n_procs - 1) then
      if (finish > n_particles) then
        ! If we have extra sites sampled, we will simply discard the extra
        ! ones on the last processor
        index_temp = n_particles - start

      elseif (finish < n_particles) then
        ! If we have too few sites, repeat sites from the very end of the
        ! fission bank
        sites_needed = n_particles - finish
        do i = 1, int(sites_needed,4)
          index_temp = index_temp + 1
          temp_sites(index_temp) = fission_bank(n_bank - sites_needed + i)
        end do
      end if

      ! the last processor should not be sending sites to right
      finish = bank_last
    end if

    call timer_stop(time_bank_sample)
    call timer_start(time_bank_sendrecv)

#ifdef MPI
    ! ==========================================================================
    ! SEND BANK SITES TO NEIGHBORS

    index_local = 1
    n_request = 0

    ! Determine the index of the processor which has the first part of the
    ! source_bank for the local processor
    neighbor = start / maxwork

    SEND_SITES: do while (start < finish)
      ! Determine the number of sites to send
      n = min((neighbor + 1)*maxwork, finish) - start

      ! Initiate an asynchronous send of source sites to the neighboring
      ! process
      if (neighbor /= rank) then
        n_request = n_request + 1
        call MPI_ISEND(temp_sites(index_local), n, MPI_BANK, neighbor, &
             rank, MPI_COMM_WORLD, request(n_request), mpi_err)
      end if

      ! Increment all indices
      start       = start       + n
      index_local = index_local + n
      neighbor    = neighbor    + 1

      ! Check for sites out of bounds -- this only happens in the rare
      ! circumstance that a processor close to the end has so many sites that
      ! it would exceed the bank on the last processor
      if (neighbor > n_procs - 1) exit
    end do SEND_SITES

    ! ==========================================================================
    ! RECEIVE BANK SITES FROM NEIGHBORS OR TEMPORARY BANK

    start = bank_first - 1
    index_local = 1

    ! Determine what process has the source sites that will need to be stored at
    ! the beginning of this processor's source bank.

    if (start >= bank_position(n_procs)) then
      neighbor = n_procs - 1
    else
      neighbor = binary_search(bank_position, n_procs, start) - 1
    end if

    RECV_SITES: do while (start < bank_last)
      ! Determine how many sites need to be received
      if (neighbor == n_procs - 1) then
        n = min(n_particles, (rank+1)*maxwork) - start
      else
        n = min(bank_position(neighbor+2), min(n_particles, &
             (rank+1)*maxwork)) - start
      end if

      if (neighbor /= rank) then
        ! If the source sites are not on this processor, initiate an
        ! asynchronous receive for the source sites

        n_request = n_request + 1
        call MPI_IRECV(source_bank(index_local), n, MPI_BANK, &
             neighbor, neighbor, MPI_COMM_WORLD, request(n_request), mpi_err)

      else
        ! If the source sites are on this procesor, we can simply copy them
        ! from the temp_sites bank

        index_temp = start - bank_position(rank+1) + 1
        source_bank(index_local:index_local+n-1) = &
             temp_sites(index_temp:index_temp+n-1)
      end if

      ! Increment all indices
      start       = start       + n
      index_local = index_local + n
      neighbor    = neighbor    + 1
    end do RECV_SITES

    ! Since we initiated a series of asynchronous ISENDs and IRECVs, now we have
    ! to ensure that the data has actually been communicated before moving on to
    ! the next generation

    call MPI_WAITALL(n_request, request, MPI_STATUSES_IGNORE, mpi_err)

    ! Deallocate space for bank_position on the very last generation
    if (current_batch == n_batches .and. current_gen == gen_per_batch) &
         deallocate(bank_position)
#else
    source_bank = temp_sites(1:n_particles)
#endif

    call timer_stop(time_bank_sendrecv)

    ! Deallocate space for the temporary source bank on the last generation
    if (current_batch == n_batches .and. current_gen == gen_per_batch) &
         deallocate(temp_sites)

  end subroutine synchronize_bank

!===============================================================================
! SHANNON_ENTROPY calculates the Shannon entropy of the fission source
! distribution to assess source convergence
!===============================================================================

  subroutine shannon_entropy()

    integer :: ent_idx        ! entropy index
    integer :: i, j, k        ! index for bank sites
    integer :: n              ! # of boxes in each dimension
    logical :: sites_outside  ! were there sites outside entropy box?
    type(StructuredMesh), pointer :: m => null()

    ! Get pointer to entropy mesh
    m => entropy_mesh

    ! On the first pass through this subroutine, we need to determine how big
    ! the entropy mesh should be in each direction and then allocate a
    ! three-dimensional array to store the fraction of source sites in each mesh
    ! box

    if (.not. allocated(entropy_p)) then
      if (.not. allocated(m % dimension)) then
        ! If the user did not specify how many mesh cells are to be used in
        ! each direction, we automatically determine an appropriate number of
        ! cells
        n = ceiling((n_particles/20)**(1.0/3.0))

        ! copy dimensions
        m % n_dimension = 3
        allocate(m % dimension(3))
        m % dimension = n
      end if

      ! allocate and determine width
      allocate(m % width(3))
      m % width = (m % upper_right - m % lower_left) / m % dimension

      ! allocate p
      allocate(entropy_p(1, m % dimension(1), m % dimension(2), &
           m % dimension(3)))
    end if

    ! count number of fission sites over mesh
    call count_bank_sites(m, fission_bank, entropy_p, &
         size_bank=n_bank, sites_outside=sites_outside)

    ! display warning message if there were sites outside entropy box
    if (sites_outside) then
      message = "Fission source site(s) outside of entropy box."
      call warning()
    end if

    ! sum values to obtain shannon entropy
    if (master) then
      ! Normalize to total weight of bank sites
      entropy_p = entropy_p / sum(entropy_p)

      ent_idx = current_gen + gen_per_batch*(current_batch - 1)
      entropy(ent_idx) = ZERO
      do i = 1, m % dimension(1)
        do j = 1, m % dimension(2)
          do k = 1, m % dimension(3)
            if (entropy_p(1,i,j,k) > ZERO) then
              entropy(ent_idx) = entropy(ent_idx) - &
                   entropy_p(1,i,j,k) * log(entropy_p(1,i,j,k))/log(TWO)
            end if
          end do
        end do
      end do
    end if

  end subroutine shannon_entropy

!===============================================================================
! CALCULATE_KEFF calculates the single batch estimate of keff as well as the
! mean and standard deviation of the mean for active batches
!===============================================================================

  subroutine calculate_keff()

    real(8) :: temp(2) ! used to reduce sum and sum_sq
    real(8) :: alpha   ! significance level for CI
    real(8) :: t_value ! t-value for confidence intervals

    message = "Calculate batch keff..."
    call write_message(8)

    ! =========================================================================
    ! SINGLE-BATCH ESTIMATE OF K-EFFECTIVE

#ifdef MPI
    if (.not. reduce_tallies) then
      ! Reduce value of k_batch if running in parallel
      if (master) then
        call MPI_REDUCE(MPI_IN_PLACE, k_batch(current_batch), 1, MPI_REAL8, &
             MPI_SUM, 0, MPI_COMM_WORLD, mpi_err)
      else
        ! Receive buffer not significant at other processors
        call MPI_REDUCE(k_batch(current_batch), temp, 1, MPI_REAL8, &
             MPI_SUM, 0, MPI_COMM_WORLD, mpi_err)
      end if
    end if
#endif

    ! Normalize single batch estimate of k
    if (master) then
      k_batch(current_batch) = k_batch(current_batch) / &
           (n_particles * gen_per_batch)
    end if

    ! =========================================================================
    ! ACCUMULATED K-EFFECTIVE AND ITS VARIANCE

    if (reduce_tallies) then
      ! In this case, global_tallies has already been reduced, so we don't
      ! need to perform any more reductions and just take the values from
      ! global_tallies directly

      ! Sample mean of keff
      keff = global_tallies(K_TRACKLENGTH) % sum / n_realizations

      if (n_realizations > 1) then
        if (confidence_intervals) then
          ! Calculate t-value for confidence intervals
          alpha = ONE - CONFIDENCE_LEVEL
          t_value = t_percentile(ONE - alpha/TWO, n_realizations - 1)
        else
          t_value = ONE
        end if

        ! Standard deviation of the sample mean of k
        keff_std = t_value * sqrt((global_tallies(K_TRACKLENGTH) % sum_sq / &
             n_realizations - keff * keff) / (n_realizations - 1))
      end if
    else
      ! In this case, no reduce was ever done on global_tallies. Thus, we need
      ! to reduce the values in sum and sum^2 to get the sample mean and its
      ! standard deviation

#ifdef MPI
      call MPI_REDUCE(global_tallies(K_TRACKLENGTH) % sum, temp, 2, &
           MPI_REAL8, MPI_SUM, 0, MPI_COMM_WORLD, mpi_err)
#else
      temp(1) = global_tallies(K_TRACKLENGTH) % sum
      temp(2) = global_tallies(K_TRACKLENGTH) % sum_sq
#endif

      ! Sample mean of k
      keff = temp(1) / n_realizations

      if (n_realizations > 1) then
        if (confidence_intervals) then
          ! Calculate t-value for confidence intervals
          alpha = ONE - CONFIDENCE_LEVEL
          t_value = t_percentile(ONE - alpha/TWO, n_realizations - 1)
        else
          t_value = ONE
        end if

        ! Standard deviation of the sample mean of k
        keff_std = t_value * sqrt((temp(2)/n_realizations - keff*keff) / &
             (n_realizations - 1))
      end if
    end if

#ifdef MPI
    ! Broadcast new keff value to all processors
    call MPI_BCAST(keff, 1, MPI_REAL8, 0, MPI_COMM_WORLD, mpi_err)
#endif

    ! Reset global tally results
    if (.not. active_batches) then
      call reset_result(global_tallies)
      n_realizations = 0
    end if

  end subroutine calculate_keff

!===============================================================================
! COUNT_SOURCE_FOR_UFS determines the source fraction in each UFS mesh cell and
! reweights the source bank so that the sum of the weights is equal to
! n_particles. The 'source_frac' variable is used later to bias the production
! of fission sites
!===============================================================================

  subroutine count_source_for_ufs()

    real(8) :: total         ! total weight in source bank
    logical :: sites_outside ! were there sites outside the ufs mesh?
#ifdef MPI
    integer :: n             ! total number of ufs mesh cells
#endif

    if (current_batch == 1 .and. current_gen == 1) then
      ! On the first generation, just assume that the source is already evenly
      ! distributed so that effectively the production of fission sites is not
      ! biased

      source_frac = ufs_mesh % volume_frac

    else
      ! count number of source sites in each ufs mesh cell
      call count_bank_sites(ufs_mesh, source_bank, source_frac, &
           sites_outside=sites_outside)

      ! Check for sites outside of the mesh
      if (master .and. sites_outside) then
        message = "Source sites outside of the UFS mesh!"
        call fatal_error()
      end if

#ifdef MPI
      ! Send source fraction to all processors
      n = product(ufs_mesh % dimension)
      call MPI_BCAST(source_frac, n, MPI_REAL8, 0, MPI_COMM_WORLD, mpi_err)
#endif

      ! Normalize to total weight to get fraction of source in each cell
      total = sum(source_frac)
      source_frac = source_frac / total

      ! Since the total starting weight is not equal to n_particles, we need to
      ! renormalize the weight of the source sites

      source_bank % wgt = source_bank % wgt * n_particles / total
    end if

  end subroutine count_source_for_ufs

end module eigenvalue
