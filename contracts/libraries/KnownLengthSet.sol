// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/**
 * @dev This is like EnumerableSet 
 * But it doesn't use arrays for gas efficiency
 * It gets length of the set from outside
 */
library KnownLengthSet {
    struct UintSet {
        // index => value
        mapping(uint256 => uint256) _values;
        
        // value => index
        mapping(uint256 => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not already present.
     */
    function add(UintSet storage set, uint256 value, uint256 currentLength) internal returns (bool) {
        if (!contains(set, value)) {
            set._values[currentLength] = value;
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = currentLength + 1;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was present.
     */
    function remove(UintSet storage set, uint256 value, uint256 currentLength) internal returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element we delete the last element but
            // if the element is not the last one, we swap them first

            uint256 valueIndex = position - 1;
            uint256 lastIndex = currentLength - 1;

            if (valueIndex != lastIndex) {
                uint256 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            delete set._values[lastIndex];

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return set._values[index];
    }
}