module plot_header

  use constants

  implicit none

!===============================================================================
! ObjectColor holds color information for plotted objects
!===============================================================================

  type ObjectColor
    integer :: rgb(3)
  end type ObjectColor

!===============================================================================
! PLOT holds plot information
!===============================================================================

  type Plot
    integer :: id                    ! Unique ID
    character(MAX_LINE_LEN) :: path_plot ! path for plot file
    integer :: type                  ! Type
    integer :: color_by              ! quantity to color regions by
    real(8) :: origin(3)             ! xyz center of plot location
    real(8) :: width(3)              ! xyz widths of plot
    integer :: basis                 ! direction of plot slice 
    integer :: pixels(2)             ! pixel width/height of plot slice
    type(ObjectColor) :: not_found   ! color for positions where no cell found
    type(ObjectColor), allocatable :: colors(:) ! colors of cells/mats
  end type Plot

  integer :: PLOT_TYPE_SLICE = 1
  integer :: PLOT_TYPE_POINTS = 2

  integer :: PLOT_BASIS_XY = 1
  integer :: PLOT_BASIS_XZ = 2
  integer :: PLOT_BASIS_YZ = 3

  integer :: PLOT_COLOR_CELLS = 1
  integer :: PLOT_COLOR_MATS = 2


end module plot_header
